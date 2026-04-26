{
  description = "flake-skills: lib.mkSkillFlake for building Claude Code skill flakes";

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

      mkSkillFlake = import ./lib/default.nix;

      # Acceptance fixture: build the example skill via the lib and reuse it
      # for the checks below.
      fixture = mkSkillFlake {
        inherit nixpkgs;
        skillName = "example-skill";
        src = ./tests/example-skill;
      };
    in
    {
      lib = {
        inherit mkSkillFlake;
      };

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          skill = fixture.packages.${system}.default;
          installApp = fixture.apps.${system}.install.program;
          previewApp = fixture.apps.${system}.preview.program;
        in
        {
          # 1. Package builds.
          example-skill-builds = skill;

          # 2. Layout is correct: required files present, plumbing/hidden absent.
          example-skill-layout =
            pkgs.runCommand "example-skill-layout-check"
              {
                nativeBuildInputs = [ pkgs.coreutils ];
              }
              ''
                set -eu
                root=${skill}/share/claude-skills/example-skill
                test -f "$root/SKILL.md"
                test -f "$root/references/note.md"
                test -f "$root/scripts/run.sh"
                test ! -e "$root/flake.nix"
                test ! -e "$root/.hidden"
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
                grep -q "Would symlink" "$TMPDIR/preview.out"
                grep -q "example-skill" "$TMPDIR/preview.out"

                touch "$out"
              '';
        }
      );
    };
}
