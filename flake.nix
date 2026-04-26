{
  description = "flake-skills: lib.mkSkillFlake + lib.mkAllSkillsFlake for building Claude Code skill flakes";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # `self` plumbed in so lib can bake provenance (upstreamUrl, rev,
      # narHash, dirty) into each skill's sentinel without callers having to.
      flakeLib = import ./lib { inherit self; };

      # Single-skill fixture.
      fixture = flakeLib.mkSkillFlake {
        inherit nixpkgs;
        skillName = "example-skill";
        src = ./tests/example-skill;
      };

      # Multi-skill fixture: directory containing alpha/ + beta/ (and a
      # not-a-skill/ subdir + a top-level README.md to exercise discovery
      # filtering).
      fixtureAll = flakeLib.mkAllSkillsFlake {
        inherit nixpkgs;
        skillsDir = ./tests/example-skills-dir;
        name = "example-skills-dir";
      };
    in
    {
      lib = flakeLib;

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Single-skill artifacts.
          skill = fixture.packages.${system}.default;
          installApp = fixture.apps.${system}.install.program;
          previewApp = fixture.apps.${system}.preview.program;

          # Multi-skill artifacts.
          allSkills = fixtureAll.packages.${system}.default;
          alphaPkg = fixtureAll.packages.${system}.alpha;
          betaPkg = fixtureAll.packages.${system}.beta;
          installAllApp = fixtureAll.apps.${system}.install.program;
          previewAllApp = fixtureAll.apps.${system}.preview.program;
        in
        {
          # ──────────────────────────────────────────────────────────────
          # Single-skill checks (mkSkillFlake).
          # ──────────────────────────────────────────────────────────────

          # 1. Package builds.
          example-skill-builds = skill;

          # 2. Layout is correct: required files present, plumbing/hidden absent,
          #    sentinel JSON present with the expected required fields.
          example-skill-layout =
            pkgs.runCommand "example-skill-layout-check"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.jq
                ];
              }
              ''
                set -eu
                root=${skill}/share/claude-skills/example-skill
                test -f "$root/SKILL.md"
                test -f "$root/references/note.md"
                test -f "$root/scripts/run.sh"
                test ! -e "$root/flake.nix"
                test ! -e "$root/.hidden"

                sentinel="$root/.flake-skills-managed.json"
                test -f "$sentinel"
                # Required fields must all be present and non-null.
                for field in schemaVersion managedBy managedByRev \
                             managedByDirty managedByNarHash skillName version; do
                  if [ "$(jq -r --arg f "$field" 'has($f)' "$sentinel")" != "true" ]; then
                    echo "sentinel missing field: $field" >&2
                    exit 1
                  fi
                done
                # Sanity-check a couple of values.
                test "$(jq -r '.skillName' "$sentinel")" = "example-skill"
                test "$(jq -r '.schemaVersion' "$sentinel")" = "1"
                # managedByRev should be a clean SHA (no `-dirty` suffix).
                rev=$(jq -r '.managedByRev' "$sentinel")
                case "$rev" in
                  *-dirty)
                    echo "managedByRev contains -dirty suffix: $rev" >&2
                    exit 1
                    ;;
                esac

                touch "$out"
              '';

          # 3. Install obeys CLAUDE_SKILLS_DIR; creates a symlink and a GC root
          #    in the override dirs; does not write to $HOME.
          example-skill-install-env =
            pkgs.runCommand "example-skill-install-env-check"
              {
                nativeBuildInputs = [ pkgs.coreutils ];
              }
              ''
                set -eu
                export HOME="$TMPDIR/fake-home"
                mkdir -p "$HOME/.claude/skills"
                export CLAUDE_SKILLS_DIR="$TMPDIR/skills-target"
                export NIX_GCROOTS_DIR="$TMPDIR/gcroots"
                mkdir -p "$NIX_GCROOTS_DIR"

                ${installApp}

                # Content is reachable through the symlink.
                test -f "$CLAUDE_SKILLS_DIR/example-skill/SKILL.md"
                test -f "$CLAUDE_SKILLS_DIR/example-skill/references/note.md"
                test -f "$CLAUDE_SKILLS_DIR/example-skill/scripts/run.sh"

                # The user-facing path is a symlink (not a copied directory).
                test -L "$CLAUDE_SKILLS_DIR/example-skill"

                # Symlink target is in the Nix store.
                target=$(readlink "$CLAUDE_SKILLS_DIR/example-skill")
                case "$target" in
                  /nix/store/*) ;;
                  *) echo "Expected store-path target, got: $target" >&2; exit 1 ;;
                esac

                # GC root was registered.
                test -L "$NIX_GCROOTS_DIR/claude-skill-example-skill"
                gctarget=$(readlink "$NIX_GCROOTS_DIR/claude-skill-example-skill")
                case "$gctarget" in
                  /nix/store/*) ;;
                  *) echo "Expected store-path GC root, got: $gctarget" >&2; exit 1 ;;
                esac

                # Real $HOME/.claude/skills was untouched.
                test ! -e "$HOME/.claude/skills/example-skill"

                touch "$out"
              '';

          # 4. Preview is read-only: HOME and target_root unchanged after run.
          example-skill-preview-readonly =
            pkgs.runCommand "example-skill-preview-readonly-check"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.findutils
                ];
              }
              ''
                set -eu
                export HOME="$TMPDIR/fake-home"
                mkdir -p "$HOME/.claude/skills"
                export CLAUDE_SKILLS_DIR="$TMPDIR/skills-target"

                snapshot() {
                  find "$HOME" "$CLAUDE_SKILLS_DIR" 2>/dev/null | sort || true
                }
                before=$(snapshot)

                ${previewApp} > "$TMPDIR/preview.out"

                after=$(snapshot)
                if [ "$before" != "$after" ]; then
                  echo "Preview modified the filesystem!" >&2
                  diff <(echo "$before") <(echo "$after") >&2 || true
                  exit 1
                fi

                grep -q "preview" "$TMPDIR/preview.out"
                grep -q "Target directory" "$TMPDIR/preview.out"
                grep -q "example-skill" "$TMPDIR/preview.out"

                touch "$out"
              '';

          # ──────────────────────────────────────────────────────────────
          # Multi-skill checks (mkAllSkillsFlake).
          # ──────────────────────────────────────────────────────────────

          # 5. Discovery + aggregate builds: symlinkJoined output contains
          #    BOTH alpha and beta SKILL.md files.
          example-skills-dir-aggregate-builds =
            pkgs.runCommand "example-skills-dir-aggregate-check"
              {
                nativeBuildInputs = [ pkgs.coreutils ];
              }
              ''
                set -eu
                root=${allSkills}/share/claude-skills
                test -f "$root/alpha/SKILL.md"
                test -f "$root/beta/SKILL.md"
                test -f "$root/beta/references/notes.md"
                test -f "$root/beta/scripts/run.sh"

                # not-a-skill/ must not have been promoted to a skill.
                test ! -e "$root/not-a-skill"

                # Filtering: hidden files / top-level README must not appear.
                test ! -e "$root/beta/.hidden"
                test ! -e "$root/README.md"

                touch "$out"
              '';

          # 6. Per-skill packages exposed as packages.<system>.<name>.
          example-skills-dir-per-skill =
            pkgs.runCommand "example-skills-dir-per-skill-check"
              {
                nativeBuildInputs = [ pkgs.coreutils ];
              }
              ''
                set -eu
                test -f ${alphaPkg}/share/claude-skills/alpha/SKILL.md
                test ! -e ${alphaPkg}/share/claude-skills/beta

                test -f ${betaPkg}/share/claude-skills/beta/SKILL.md
                test -f ${betaPkg}/share/claude-skills/beta/references/notes.md
                test -f ${betaPkg}/share/claude-skills/beta/scripts/run.sh
                test ! -e ${betaPkg}/share/claude-skills/alpha

                touch "$out"
              '';

          # 7. Aggregate install: one symlink + one GC root per skill;
          #    $HOME untouched.
          example-skills-dir-install-env =
            pkgs.runCommand "example-skills-dir-install-env-check"
              {
                nativeBuildInputs = [ pkgs.coreutils ];
              }
              ''
                set -eu
                export HOME="$TMPDIR/fake-home"
                mkdir -p "$HOME/.claude/skills"
                export CLAUDE_SKILLS_DIR="$TMPDIR/skills-target"
                export NIX_GCROOTS_DIR="$TMPDIR/gcroots"
                mkdir -p "$NIX_GCROOTS_DIR"

                ${installAllApp}

                # Per-skill symlinks.
                test -L "$CLAUDE_SKILLS_DIR/alpha"
                test -L "$CLAUDE_SKILLS_DIR/beta"

                # Content reachable through both.
                test -f "$CLAUDE_SKILLS_DIR/alpha/SKILL.md"
                test -f "$CLAUDE_SKILLS_DIR/beta/SKILL.md"
                test -f "$CLAUDE_SKILLS_DIR/beta/references/notes.md"

                # Both symlinks target the Nix store.
                for s in alpha beta; do
                  t=$(readlink "$CLAUDE_SKILLS_DIR/$s")
                  case "$t" in
                    /nix/store/*) ;;
                    *) echo "Expected store-path target for $s, got: $t" >&2; exit 1 ;;
                  esac
                done

                # Per-skill GC roots.
                test -L "$NIX_GCROOTS_DIR/claude-skill-alpha"
                test -L "$NIX_GCROOTS_DIR/claude-skill-beta"
                for s in alpha beta; do
                  t=$(readlink "$NIX_GCROOTS_DIR/claude-skill-$s")
                  case "$t" in
                    /nix/store/*) ;;
                    *) echo "Expected store-path GC root for $s, got: $t" >&2; exit 1 ;;
                  esac
                done

                # $HOME/.claude/skills was not touched.
                test ! -e "$HOME/.claude/skills/alpha"
                test ! -e "$HOME/.claude/skills/beta"

                touch "$out"
              '';

          # 8. Aggregate preview is read-only.
          example-skills-dir-preview-readonly =
            pkgs.runCommand "example-skills-dir-preview-readonly-check"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.findutils
                ];
              }
              ''
                set -eu
                export HOME="$TMPDIR/fake-home"
                mkdir -p "$HOME/.claude/skills"
                export CLAUDE_SKILLS_DIR="$TMPDIR/skills-target"

                snapshot() {
                  find "$HOME" "$CLAUDE_SKILLS_DIR" 2>/dev/null | sort || true
                }
                before=$(snapshot)

                ${previewAllApp} > "$TMPDIR/preview.out"

                after=$(snapshot)
                if [ "$before" != "$after" ]; then
                  echo "Aggregate preview modified the filesystem!" >&2
                  diff <(echo "$before") <(echo "$after") >&2 || true
                  exit 1
                fi

                grep -q "preview" "$TMPDIR/preview.out"
                grep -q "Target directory" "$TMPDIR/preview.out"
                grep -q "alpha" "$TMPDIR/preview.out"
                grep -q "beta" "$TMPDIR/preview.out"
                grep -q "2 skill(s) total" "$TMPDIR/preview.out"

                touch "$out"
              '';
        }
      );
    };
}
