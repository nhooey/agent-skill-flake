#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP — aggregate install entrypoint (alpha + beta).
#
# Covers the 9 scope-resolution cases from the install-scope plan
# §1.4: missing --scope, personal, project (git root, git subdir,
# no-marker fail), custom (with/without --root), and subset install
# (positive + typo).
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

# Run the install app with the given args after cd'ing into <dir>.
# Bats' `run` captures exit status + output, but the cd needs to be
# inside the same shell invocation, so we use bash -c.
run_in_dir() {
  local dir=$1
  shift
  run bash -c "cd \"$dir\" && \"\$@\"" -- "$@"
}

@test "missing --scope exits non-zero with a useful message" {
  run "$INSTALL_ALL_APP"
  assert_failure
  assert_output --partial "--scope is required"
  assert_output --partial "personal, project, custom"
}

@test "--scope=personal installs under \$HOME/.claude/skills/" {
  run "$INSTALL_ALL_APP" \
    --scope=personal \
    --gcroots-dir="$GCROOTS_DIR"
  assert_success

  assert [ -L "$HOME/.claude/skills/alpha" ]
  assert [ -L "$HOME/.claude/skills/beta" ]
  assert_store_symlink "$HOME/.claude/skills/alpha"
  assert_store_symlink "$HOME/.claude/skills/beta"
}

@test "--scope=project from a git init'd dir installs at <root>/.claude/skills" {
  local proj="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$proj"
  ( cd "$proj" && git init -q -b main )

  run_in_dir "$proj" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  assert [ -L "$proj/.claude/skills/alpha" ]
  assert [ -L "$proj/.claude/skills/beta" ]
}

@test "--scope=project from a subdir resolves to the repo root, not the subdir" {
  local proj="$BATS_TEST_TMPDIR/proj-sub"
  mkdir -p "$proj/sub/deep"
  ( cd "$proj" && git init -q -b main )

  run_in_dir "$proj/sub/deep" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  assert [ -L "$proj/.claude/skills/alpha" ]
  refute [ -e "$proj/sub/deep/.claude/skills" ]
}

@test "--scope=project from a non-git, non-flake dir exits non-zero" {
  local dir="$BATS_TEST_TMPDIR/no-markers"
  mkdir -p "$dir"

  run_in_dir "$dir" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_failure
  assert_output --partial "no project root found"
}

@test "--scope=custom without --root exits non-zero" {
  run "$INSTALL_ALL_APP" --scope=custom --gcroots-dir="$GCROOTS_DIR"
  assert_failure
  assert_output --partial "--scope=custom requires --root="
}

@test "--scope=custom --root=<path> installs at the literal path" {
  local dest="$BATS_TEST_TMPDIR/explicit-dest"
  run "$INSTALL_ALL_APP" \
    --scope=custom --root="$dest" --gcroots-dir="$GCROOTS_DIR"
  assert_success
  assert [ -L "$dest/alpha" ]
  assert [ -L "$dest/beta" ]
}

@test "subset install: positional names restrict the install set" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}" alpha
  assert_success
  assert [ -L "$CUSTOM_TARGET/alpha" ]
  refute [ -e "$CUSTOM_TARGET/beta" ]
}

@test "subset install: unknown name is a hard error listing available skills" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}" doesnotexist
  assert_failure
  assert_output --partial "unknown skill name: doesnotexist"
  assert_output --partial "Available skills:"
  assert_output --partial "alpha"
  assert_output --partial "beta"
  refute [ -e "$CUSTOM_TARGET/alpha" ]
}
