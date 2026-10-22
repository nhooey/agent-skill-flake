#!/usr/bin/env bats
# Inputs: CLI — the agent-skill-flake binary; ALL_SKILLS — the fixture
#         flake's aggregate (alpha + beta) store path; ALPHA_PKG — alpha's
#         store path; INSTALL_APP — the single-skill fixture's installer
#         (example-skill, a different reconcile owner).
#
# `agent-skill-flake sync-project`: the repo's effective skill set (local
# file > user-global repo entry > [defaults]) reconciled into
# <root>/.agents/skills under its own owner, other owners' entries left
# alone; the quiet skips; the skills-devshell/ skip; and `--from-hook`,
# which never fails the git command.
#
# The sandbox can't build flakes, so a stub `nix` stands in for
# `nix build`: it maps the fixture flake's installable to its store path.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  export XDG_CONFIG_HOME="$HOME/.config"
  export GIT_CONFIG_GLOBAL="$HOME/gitconfig"
  GLOBAL_CONFIG="$XDG_CONFIG_HOME/agent-skill-flake/config.toml"
  mkdir -p "$(dirname "$GLOBAL_CONFIG")"

  mkdir -p "$BATS_TEST_TMPDIR/stub-bin"
  cat >"$BATS_TEST_TMPDIR/stub-bin/nix" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "\$PWD" "\$*" >>"$BATS_TEST_TMPDIR/nix-calls"
case "\$*" in
*"build --no-link --print-out-paths path:./skill-flake#agent-skills-all") printf '%s\n' "$ALL_SKILLS" ;;
*) echo "error: stub nix cannot build: \$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/stub-bin/nix"
  export PATH="$BATS_TEST_TMPDIR/stub-bin:$PATH"

  PROJ="$BATS_TEST_TMPDIR/widget"
  make_repo "$PROJ" git@github.com:acme/widget.git
  # The path git reports, symlinks resolved (macOS /var → /private/var).
  PROJ=$(cd "$PROJ" && pwd -P)
}

make_repo() {
  local dir=$1 origin=${2:-}
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  [ -z "$origin" ] || git -C "$dir" remote add origin "$origin"
}

sync() {
  run bash -c 'cd "$1" && shift && "$@"' -- "$PROJ" "$CLI" sync-project --gcroots-dir="$GCROOTS_DIR" "$@"
}

write_local() {
  mkdir -p "$PROJ/.config/agent-skill-flake"
  printf '%s\n' "$1" >"$PROJ/.config/agent-skill-flake/config.local.toml"
}

@test "the user-global repo entry's skills are installed, with their source" {
  cat >"$GLOBAL_CONFIG" <<'EOF'
[repo."github.com/acme/widget"]
skills = ["path:./skill-flake#agent-skills-all"]
EOF
  sync
  assert_success
  assert_output --partial "skill alpha <- path:./skill-flake#agent-skills-all (user-global: $GLOBAL_CONFIG [repo.\"github.com/acme/widget\"])"
  assert_output --partial "skill beta <- path:./skill-flake#agent-skills-all (user-global:"
  assert_output --partial "agent-skill-flake: 2 project skill(s) in sync"

  assert_store_symlink "$PROJ/.agents/skills/alpha"
  assert_store_symlink "$PROJ/.agents/skills/beta"
  assert_equal "$(readlink "$PROJ/.claude/skills")" "../.agents/skills"
  assert_equal "$(jq -r .skills.alpha.installedBy "$PROJ/.agents/skills/.agent-skill-flake-lock.json")" \
    "agent-skill-flake-local"
  # nix build ran from the repo root, so relative refs resolve against it.
  assert grep -q "^$PROJ .*build --no-link --print-out-paths path:./skill-flake#agent-skills-all" "$BATS_TEST_TMPDIR/nix-calls"
}

@test "the local file is listed in the exclude block, and git ignores it" {
  write_local "skills = [\"$ALPHA_PKG\"]"
  sync
  assert_success
  assert grep -qxF '/.config/agent-skill-flake/config.local.toml' "$PROJ/.git/info/exclude"
  run git -C "$PROJ" status --porcelain --untracked-files=all
  assert_success
  assert_output ""
}

@test "the local file replaces the repo entry, and a store path needs no build" {
  cat >"$GLOBAL_CONFIG" <<'EOF'
[repo."github.com/acme/widget"]
skills = ["path:./skill-flake#agent-skills-all"]
EOF
  write_local "skills = [\"$ALPHA_PKG\"]"
  sync
  assert_success
  assert_output --partial "skill alpha <- $ALPHA_PKG (local: .config/agent-skill-flake/config.local.toml)"
  assert_store_symlink "$PROJ/.agents/skills/alpha"
  refute [ -e "$PROJ/.agents/skills/beta" ]
  refute [ -e "$BATS_TEST_TMPDIR/nix-calls" ]
}

@test "a skill dropped from the set is swept; other owners' entries stay" {
  cat >"$GLOBAL_CONFIG" <<'EOF'
[repo."github.com/acme/widget"]
skills = ["path:./skill-flake#agent-skills-all"]
EOF
  sync
  assert_success
  run bash -c 'cd "$1" && "$2" --scope=project --gcroots-dir="$3"' -- "$PROJ" "$INSTALL_APP" "$GCROOTS_DIR"
  assert_success
  mkdir -p "$PROJ/.agents/skills/team-skill"
  echo ours >"$PROJ/.agents/skills/team-skill/SKILL.md"

  write_local "skills = [\"$ALPHA_PKG\"]"
  sync
  assert_success
  assert_output --partial "reconciled (sweep): $PROJ/.agents/skills/beta"
  refute [ -e "$PROJ/.agents/skills/beta" ]
  assert_store_symlink "$PROJ/.agents/skills/alpha"
  assert_store_symlink "$PROJ/.agents/skills/example-skill"
  assert [ -f "$PROJ/.agents/skills/team-skill/SKILL.md" ]
  refute grep -qxF '/.agents/skills/beta' "$PROJ/.git/info/exclude"

  # Re-running changes nothing.
  sync
  assert_success
  refute_output --partial "reconciled (install)"
  refute_output --partial "reconciled (sweep)"
}

@test "merge mode keeps the repo entry's skills when the local file doesn't set them" {
  cat >"$GLOBAL_CONFIG" <<EOF
[repo."github.com/acme/widget"]
skills = ["$ALPHA_PKG"]
EOF
  write_local 'merge = { override = ["skills"] }
notes = "local only"'
  sync
  assert_success
  assert_output --partial "skill alpha <- $ALPHA_PKG (user-global: $GLOBAL_CONFIG [repo.\"github.com/acme/widget\"])"
}

@test "an https origin finds the same repo entry" {
  git -C "$PROJ" remote set-url origin https://github.com/acme/widget.git
  cat >"$GLOBAL_CONFIG" <<EOF
[repo."github.com/acme/widget"]
skills = ["$ALPHA_PKG"]
EOF
  sync
  assert_success
  assert_store_symlink "$PROJ/.agents/skills/alpha"
}

@test "two installables providing the same skill fail, changing nothing" {
  write_local "skills = [\"$ALPHA_PKG\", \"path:./skill-flake#agent-skills-all\"]"
  sync
  assert_failure
  assert_output --partial "skill alpha is provided by both"
  refute [ -e "$PROJ/.agents" ]
}

@test "quiet no-ops: no git repo, no origin, no entry or local file" {
  cat >"$GLOBAL_CONFIG" <<EOF
[repo."github.com/acme/widget"]
skills = ["$ALPHA_PKG"]
EOF
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run bash -c 'cd "$1" && "$2" sync-project' -- "$BATS_TEST_TMPDIR/plain" "$CLI"
  assert_success
  assert_output ""

  make_repo "$BATS_TEST_TMPDIR/no-origin"
  run bash -c 'cd "$1" && "$2" sync-project' -- "$BATS_TEST_TMPDIR/no-origin" "$CLI"
  assert_success
  assert_output ""

  make_repo "$BATS_TEST_TMPDIR/other" git@github.com:acme/other.git
  run bash -c 'cd "$1" && "$2" sync-project' -- "$BATS_TEST_TMPDIR/other" "$CLI"
  assert_success
  assert_output ""
  refute [ -e "$BATS_TEST_TMPDIR/other/.agents" ]
}

@test "a repo with its own skills-devshell/ is skipped with a note" {
  write_local "skills = [\"$ALPHA_PKG\"]"
  mkdir -p "$PROJ/skills-devshell"
  sync
  assert_success
  assert_output "agent-skill-flake: skipped $PROJ: its skills-devshell/ owns project skills"
  refute [ -e "$PROJ/.agents" ]
}

@test "--from-hook acts on a branch checkout, in one line" {
  write_local "skills = [\"$ALPHA_PKG\"]"
  sync --from-hook 0000000 1111111 1
  assert_success
  assert_equal "${#lines[@]}" "1"
  assert_output --partial "agent-skill-flake: 1 project skill(s) in sync"
  assert_store_symlink "$PROJ/.agents/skills/alpha"
}

@test "--from-hook ignores a file checkout" {
  write_local "skills = [\"$ALPHA_PKG\"]"
  sync --from-hook 1111111 1111111 0
  assert_success
  assert_output ""
  refute [ -e "$PROJ/.agents" ]
}

@test "--from-hook exits 0 on an error, in two lines" {
  write_local 'skills = ["path:./missing#nothing"]'
  sync --from-hook 0000000 1111111 1
  assert_success
  assert_equal "${#lines[@]}" "2"
  assert_output --partial "agent-skill-flake: sync-project failed (exit 1)"

  write_local 'skills = ['
  sync --from-hook 0000000 1111111 1
  assert_success
  assert_output --partial "sync-project failed"

  # Without --from-hook the same error fails.
  sync
  assert_failure
}

@test "the registered git config hook runs sync-project on worktree add" {
  cat >"$GLOBAL_CONFIG" <<EOF
[repo."github.com/acme/widget"]
skills = ["$ALPHA_PKG"]
EOF
  run "$CLI" apply
  assert_success
  if ! git -C "$PROJ" hook list post-checkout 2>/dev/null | grep -q agent-skill-flake-sync; then
    skip "this git ($(git --version)) has no config-based hooks"
  fi

  # The hook command finds agent-skill-flake on PATH, as after
  # `nix profile install`. It uses the default GC-roots dir, which names
  # $USER (unset in the build sandbox) and may not be writable there.
  export USER="${USER:-tester}"
  mkdir -p "$BATS_TEST_TMPDIR/cli-bin"
  ln -s "$CLI" "$BATS_TEST_TMPDIR/cli-bin/agent-skill-flake"
  PATH="$BATS_TEST_TMPDIR/cli-bin:$PATH" run git -C "$PROJ" worktree add -q -b side "$BATS_TEST_TMPDIR/widget-wt"
  assert_success
  assert_output --partial "agent-skill-flake: 1 project skill(s) in sync"
  assert_store_symlink "$BATS_TEST_TMPDIR/widget-wt/.agents/skills/alpha"
}
