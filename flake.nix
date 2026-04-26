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

      # Internal helpers — used here to expose a top-level `reap` app that
      # works without any embedded skill set (pure cleanup tool).
      internal = import ./lib/internal.nix { inherit nixpkgs; };

      reapTopLevel =
        system:
        internal.mkReap system {
          appName = "flake-skills";
          inherit (flakeLib) provenance;
          installRoot = "$HOME/.claude/skills";
          envVarOverride = "CLAUDE_SKILLS_DIR";
        };

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

      apps = forAllSystems (system: {
        reap = {
          type = "app";
          program = "${reapTopLevel system}/bin/reap-flake-skills";
        };
      });

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
          uninstallAllApp = fixtureAll.apps.${system}.uninstall.program;
          previewAllApp = fixtureAll.apps.${system}.preview.program;
          reapAllApp = fixtureAll.apps.${system}.reap.program;
          reconcileAllApp = fixtureAll.apps.${system}.reconcile.program;
          reapSkillApp = fixture.apps.${system}.reap.program;
          uninstallSkillApp = fixture.apps.${system}.uninstall.program;
        in
        {
          # ──────────────────────────────────────────────────────────────
          # Single-skill checks (mkSkillFlake).
          # ──────────────────────────────────────────────────────────────

          # 1. Package builds.
          example-skill-builds = skill;

          # 1b. mkSkillFlake exposes the skill at `packages.<system>.skill-<name>`
          #     by default — `skill-` prefix prevents collision with same-named
          #     entries in nixpkgs or aggregator flakes (e.g. `git`).
          example-skill-package-named =
            pkgs.runCommand "example-skill-package-named-check"
              { nativeBuildInputs = [ pkgs.coreutils ]; }
              ''
                set -eu
                # Forces eval of the renamed attribute; eval would fail
                # if the default ever reverted to bare `skillName`.
                test -f ${fixture.packages.${system}."skill-example-skill"}/share/claude-skills/example-skill/SKILL.md
                touch "$out"
              '';

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

          # 9. Reap removes a managed-but-broken entry (symlink target gone)
          #    and its matching GC root, while leaving unmanaged entries alone.
          example-skills-dir-reap-broken =
            pkgs.runCommand "example-skills-dir-reap-broken-check"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.jq
                ];
              }
              ''
                set -eu
                export HOME="$TMPDIR/fake-home"
                export CLAUDE_SKILLS_DIR="$TMPDIR/skills-target"
                export NIX_GCROOTS_DIR="$TMPDIR/gcroots"
                mkdir -p "$CLAUDE_SKILLS_DIR" "$NIX_GCROOTS_DIR"

                # Forge a managed-but-broken entry: symlink to a non-existent
                # store path, plus a same-named GC root (the
                # naming-convention ownership signal reap falls back to when
                # the sentinel is unreadable).
                bogus=/nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-bogus
                ln -sfn "$bogus/share/claude-skills/foo" "$CLAUDE_SKILLS_DIR/foo"
                ln -sfn "$bogus" "$NIX_GCROOTS_DIR/claude-skill-foo"

                # Unmanaged entry — must NOT be touched.
                mkdir -p "$CLAUDE_SKILLS_DIR/manual-skill"
                echo manual > "$CLAUDE_SKILLS_DIR/manual-skill/SKILL.md"

                ${reapAllApp}

                # Broken managed entry + GC root reaped.
                test ! -L "$CLAUDE_SKILLS_DIR/foo"
                test ! -e "$NIX_GCROOTS_DIR/claude-skill-foo"

                # Manual entry untouched.
                test -d "$CLAUDE_SKILLS_DIR/manual-skill"
                test -f "$CLAUDE_SKILLS_DIR/manual-skill/SKILL.md"

                touch "$out"
              '';

          # 10. Reconcile installs the declared set AND sweeps stray managed
          #     entries while leaving unmanaged entries alone.
          example-skills-dir-reconcile =
            pkgs.runCommand "example-skills-dir-reconcile-check"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.jq
                ];
              }
              ''
                set -eu
                export HOME="$TMPDIR/fake-home"
                export CLAUDE_SKILLS_DIR="$TMPDIR/skills-target"
                export NIX_GCROOTS_DIR="$TMPDIR/gcroots"
                mkdir -p "$CLAUDE_SKILLS_DIR" "$NIX_GCROOTS_DIR"

                # Stray managed entry: reuse alpha's content (so the sentinel
                # genuinely matches our managedBy URL) but mount it under a
                # name that isn't in the declared set. Reconcile must sweep
                # it once it sees alpha+beta as the keep set.
                ln -sfn ${alphaPkg}/share/claude-skills/alpha \
                  "$CLAUDE_SKILLS_DIR/stale"
                ln -sfn ${alphaPkg} "$NIX_GCROOTS_DIR/claude-skill-stale"

                # Unmanaged entry — must NOT be swept.
                mkdir -p "$CLAUDE_SKILLS_DIR/manual-skill"
                echo manual > "$CLAUDE_SKILLS_DIR/manual-skill/SKILL.md"

                ${reconcileAllApp}

                # Declared skills installed.
                test -L "$CLAUDE_SKILLS_DIR/alpha"
                test -L "$CLAUDE_SKILLS_DIR/beta"
                test -f "$CLAUDE_SKILLS_DIR/alpha/SKILL.md"
                test -f "$CLAUDE_SKILLS_DIR/beta/SKILL.md"
                test -L "$NIX_GCROOTS_DIR/claude-skill-alpha"
                test -L "$NIX_GCROOTS_DIR/claude-skill-beta"

                # Stray managed entry swept.
                test ! -L "$CLAUDE_SKILLS_DIR/stale"
                test ! -e "$NIX_GCROOTS_DIR/claude-skill-stale"

                # Unmanaged entry untouched.
                test -d "$CLAUDE_SKILLS_DIR/manual-skill"
                test -f "$CLAUDE_SKILLS_DIR/manual-skill/SKILL.md"

                touch "$out"
              '';

          # 11. Single-skill flake exposes a reap app — sanity check that
          #     mk-skill-flake wires it correctly. (Behavior is shared with
          #     the multi-skill check above; this just verifies the binding.)
          example-skill-reap-exists =
            pkgs.runCommand "example-skill-reap-exists-check"
              { }
              ''
                test -x ${reapSkillApp}
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

          # ──────────────────────────────────────────────────────────────
          # Lock file + uninstall checks.
          # ──────────────────────────────────────────────────────────────

          # 12. Install populates the aggregate lock with one entry per
          #     installed skill, copying provenance from the per-skill
          #     sentinel. Reap, reconcile, and uninstall all read/write
          #     the same file.
          example-skills-dir-install-writes-lock =
            pkgs.runCommand "example-skills-dir-install-lock-check"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.jq
                ];
              }
              ''
                set -eu
                export HOME="$TMPDIR/fake-home"
                export CLAUDE_SKILLS_DIR="$TMPDIR/skills-target"
                export NIX_GCROOTS_DIR="$TMPDIR/gcroots"
                mkdir -p "$NIX_GCROOTS_DIR"

                ${installAllApp}

                lock="$CLAUDE_SKILLS_DIR/.flake-skills-lock.json"
                test -f "$lock"

                # Schema and structure.
                test "$(jq -r '.schemaVersion' "$lock")" = "1"
                test "$(jq -r '.skills | keys | sort | join(",")' "$lock")" = "alpha,beta"

                # Every entry has the fields we promised: provenance from
                # the sentinel + storePath + installedAt added by upsert.
                for s in alpha beta; do
                  for field in managedBy managedByRev managedByDirty \
                               managedByNarHash skillName version \
                               storePath installedAt; do
                    if [ "$(jq -r --arg s "$s" --arg f "$field" \
                            '.skills[$s] | has($f)' "$lock")" != "true" ]; then
                      echo "lock entry $s missing field: $field" >&2
                      exit 1
                    fi
                  done
                  # storePath should match the actual symlink target's
                  # store-path prefix.
                  store_path=$(jq -r --arg s "$s" '.skills[$s].storePath' "$lock")
                  case "$store_path" in
                    /nix/store/*) ;;
                    *) echo "expected /nix/store path for $s, got: $store_path" >&2; exit 1 ;;
                  esac
                done

                touch "$out"
              '';

          # 13. Uninstall (multi-skill): removes one named entry — symlink,
          #     GC root, and lock entry — leaves the other alone.
          example-skills-dir-uninstall =
            pkgs.runCommand "example-skills-dir-uninstall-check"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.jq
                ];
              }
              ''
                set -eu
                export HOME="$TMPDIR/fake-home"
                export CLAUDE_SKILLS_DIR="$TMPDIR/skills-target"
                export NIX_GCROOTS_DIR="$TMPDIR/gcroots"
                mkdir -p "$NIX_GCROOTS_DIR"

                ${installAllApp}
                ${uninstallAllApp} alpha

                # alpha is gone in all three places.
                test ! -L "$CLAUDE_SKILLS_DIR/alpha"
                test ! -e "$NIX_GCROOTS_DIR/claude-skill-alpha"
                lock="$CLAUDE_SKILLS_DIR/.flake-skills-lock.json"
                test "$(jq 'has("skills") and (.skills | has("alpha") | not)' "$lock")" = "true"

                # beta is untouched.
                test -L "$CLAUDE_SKILLS_DIR/beta"
                test -L "$NIX_GCROOTS_DIR/claude-skill-beta"
                test "$(jq -r '.skills.beta.skillName' "$lock")" = "beta"

                touch "$out"
              '';

          # 14. Uninstall refuses to touch entries it didn't install
          #     (manual skill dirs / foreign-lineage symlinks).
          example-skills-dir-uninstall-refuses-unmanaged =
            pkgs.runCommand "example-skills-dir-uninstall-refuses-check"
              {
                nativeBuildInputs = [ pkgs.coreutils ];
              }
              ''
                set -eu
                export HOME="$TMPDIR/fake-home"
                export CLAUDE_SKILLS_DIR="$TMPDIR/skills-target"
                export NIX_GCROOTS_DIR="$TMPDIR/gcroots"
                mkdir -p "$CLAUDE_SKILLS_DIR" "$NIX_GCROOTS_DIR"

                # User's hand-rolled skill — must not be touched.
                mkdir -p "$CLAUDE_SKILLS_DIR/manual-skill"
                echo manual > "$CLAUDE_SKILLS_DIR/manual-skill/SKILL.md"

                # Should exit non-zero (every requested name skipped).
                if ${uninstallAllApp} manual-skill 2>"$TMPDIR/err"; then
                  echo "uninstall should have failed on unmanaged entry" >&2
                  exit 1
                fi
                grep -q "not managed by" "$TMPDIR/err"

                # Manual skill is intact.
                test -d "$CLAUDE_SKILLS_DIR/manual-skill"
                test -f "$CLAUDE_SKILLS_DIR/manual-skill/SKILL.md"

                touch "$out"
              '';

          # 15. Single-skill uninstall (no args) defaults to the skill the
          #     flake was built for.
          example-skill-uninstall-default =
            pkgs.runCommand "example-skill-uninstall-default-check"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.jq
                ];
              }
              ''
                set -eu
                export HOME="$TMPDIR/fake-home"
                export CLAUDE_SKILLS_DIR="$TMPDIR/skills-target"
                export NIX_GCROOTS_DIR="$TMPDIR/gcroots"
                mkdir -p "$NIX_GCROOTS_DIR"

                ${installApp}
                test -L "$CLAUDE_SKILLS_DIR/example-skill"

                # No-args uninstall — should pick up the default skill.
                ${uninstallSkillApp}

                test ! -L "$CLAUDE_SKILLS_DIR/example-skill"
                test ! -e "$NIX_GCROOTS_DIR/claude-skill-example-skill"
                lock="$CLAUDE_SKILLS_DIR/.flake-skills-lock.json"
                test "$(jq '.skills | length' "$lock")" = "0"

                touch "$out"
              '';

          # 16. Reap drops the lock entry along with the symlink + GC root.
          example-skills-dir-reap-prunes-lock =
            pkgs.runCommand "example-skills-dir-reap-prunes-lock-check"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.jq
                ];
              }
              ''
                set -eu
                export HOME="$TMPDIR/fake-home"
                export CLAUDE_SKILLS_DIR="$TMPDIR/skills-target"
                export NIX_GCROOTS_DIR="$TMPDIR/gcroots"
                mkdir -p "$CLAUDE_SKILLS_DIR" "$NIX_GCROOTS_DIR"

                # Initialize a lock with a stale entry — simulates a state
                # left behind by a previous install whose store path has
                # since been GC'd.
                printf '%s' '{"schemaVersion":1,"skills":{"foo":{"managedBy":"github:nhooey/flake-skills","skillName":"foo"}}}' \
                  > "$CLAUDE_SKILLS_DIR/.flake-skills-lock.json"

                # Forge a managed-but-broken entry: symlink to a bogus
                # store path + same-named GC root.
                bogus=/nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-bogus
                ln -sfn "$bogus/share/claude-skills/foo" "$CLAUDE_SKILLS_DIR/foo"
                ln -sfn "$bogus" "$NIX_GCROOTS_DIR/claude-skill-foo"

                ${reapAllApp}

                # All three layers reaped.
                test ! -L "$CLAUDE_SKILLS_DIR/foo"
                test ! -e "$NIX_GCROOTS_DIR/claude-skill-foo"
                lock="$CLAUDE_SKILLS_DIR/.flake-skills-lock.json"
                test "$(jq '.skills | has("foo")' "$lock")" = "false"

                touch "$out"
              '';

          # 17. Reconcile rewrites the lock to match the declared set
          #     exactly — stray entries dropped, declared entries refreshed.
          example-skills-dir-reconcile-rewrites-lock =
            pkgs.runCommand "example-skills-dir-reconcile-rewrites-lock-check"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.jq
                ];
              }
              ''
                set -eu
                export HOME="$TMPDIR/fake-home"
                export CLAUDE_SKILLS_DIR="$TMPDIR/skills-target"
                export NIX_GCROOTS_DIR="$TMPDIR/gcroots"
                mkdir -p "$CLAUDE_SKILLS_DIR" "$NIX_GCROOTS_DIR"

                # Pre-populate a lock with a stale entry that won't appear
                # in the declared (alpha + beta) set.
                printf '%s' '{"schemaVersion":1,"skills":{"stale":{"managedBy":"github:nhooey/flake-skills","skillName":"stale"}}}' \
                  > "$CLAUDE_SKILLS_DIR/.flake-skills-lock.json"

                ${reconcileAllApp}

                lock="$CLAUDE_SKILLS_DIR/.flake-skills-lock.json"
                test "$(jq -r '.skills | keys | sort | join(",")' "$lock")" = "alpha,beta"
                test "$(jq '.skills | has("stale")' "$lock")" = "false"

                # Declared entries got fresh provenance fields populated.
                for s in alpha beta; do
                  test "$(jq -r --arg s "$s" '.skills[$s].skillName' "$lock")" = "$s"
                  test -n "$(jq -r --arg s "$s" '.skills[$s].storePath' "$lock")"
                done

                touch "$out"
              '';
        }
      );
    };
}
