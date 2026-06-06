#!/usr/bin/env bats
# Inputs: INIT_APP — the wrapped `init` scaffolder entrypoint.
#
# These exercise the SCRIPT's file-writing behavior directly (the wrapped
# bin), not `nix run` — the check sandbox has no network and no nix on PATH.
# `git` (the app's runtime input) IS available, so the remote-name path and
# the no-remote fallback can both be covered with a temp `git init`.
setup() {
  source "$BATS_HELPERS"
  export HOME="$BATS_TEST_TMPDIR/fake-home"
  mkdir -p "$HOME"
}

# Run the init app after cd'ing into <dir> (the scaffolder writes to CWD).
run_in_dir() {
  local dir=$1
  shift
  run bash -c "cd \"$dir\" && \"\$@\"" -- "$@"
}

# A git repo whose origin remote basename is `my-cool-repo`.
make_repo_with_remote() {
  local dir=$1
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q -b main
    git remote add origin "https://example.com/org/my-cool-repo.git"
  )
}

@test "a full run writes all three files and prints the root snippet" {
  local proj="$BATS_TEST_TMPDIR/full"
  make_repo_with_remote "$proj"

  run_in_dir "$proj" "$INIT_APP"
  assert_success

  # skills-devshell/flake.nix scaffolded with the resolved repo name.
  assert [ -f "$proj/skills-devshell/flake.nix" ]
  assert grep -qF 'name = "my-cool-repo-devshell";' "$proj/skills-devshell/flake.nix"
  assert grep -qF "mkDevshellSkillsFlake" "$proj/skills-devshell/flake.nix"
  # The @UPSTREAM_URL@ / @NAME@ placeholders were substituted, not left literal.
  refute grep -qF '@UPSTREAM_URL@' "$proj/skills-devshell/flake.nix"
  refute grep -qF '@NAME@' "$proj/skills-devshell/flake.nix"

  # .gitignore got the skills line.
  assert [ -f "$proj/.gitignore" ]
  assert grep -qxF '/.claude/skills/' "$proj/.gitignore"

  # Root wiring snippet printed to stdout (not written to disk).
  assert_output --partial "flakeModules.devshellSkills"
  assert_output --partial 'name = "my-cool-repo";'
  assert_output --partial "devshellSkillsHook"
}

@test "second run is idempotent: skips existing files, no duplicate gitignore line" {
  local proj="$BATS_TEST_TMPDIR/idem"
  make_repo_with_remote "$proj"

  run_in_dir "$proj" "$INIT_APP"
  assert_success

  # Capture the scaffolded flake to prove the second run leaves it untouched.
  local first
  first=$(cat "$proj/skills-devshell/flake.nix")

  run_in_dir "$proj" "$INIT_APP"
  assert_success
  assert_output --partial "skip"

  # flake.nix unchanged.
  assert_equal "$(cat "$proj/skills-devshell/flake.nix")" "$first"

  # Exactly one gitignore line, not two.
  assert_equal "$(grep -cxF '/.claude/skills/' "$proj/.gitignore")" "1"
}

@test "--force overwrites an existing scaffolded flake" {
  local proj="$BATS_TEST_TMPDIR/force"
  make_repo_with_remote "$proj"
  mkdir -p "$proj/skills-devshell"
  printf 'stale\n' >"$proj/skills-devshell/flake.nix"

  run_in_dir "$proj" "$INIT_APP" --force
  assert_success
  assert grep -qF "mkDevshellSkillsFlake" "$proj/skills-devshell/flake.nix"
  refute grep -qF "stale" "$proj/skills-devshell/flake.nix"
}

@test "--dry-run writes nothing" {
  local proj="$BATS_TEST_TMPDIR/dry"
  make_repo_with_remote "$proj"

  run_in_dir "$proj" "$INIT_APP" --dry-run
  assert_success
  assert_output --partial "would"

  refute [ -e "$proj/skills-devshell/flake.nix" ]
  refute [ -e "$proj/.gitignore" ]
}

@test "no git remote falls back to the directory basename" {
  local proj="$BATS_TEST_TMPDIR/fallback-dir-name"
  mkdir -p "$proj"
  ( cd "$proj" && git init -q -b main ) # git repo, but NO origin remote

  run_in_dir "$proj" "$INIT_APP"
  assert_success
  assert grep -qF 'name = "fallback-dir-name-devshell";' "$proj/skills-devshell/flake.nix"
}

@test "an existing trailing-newline-less .gitignore stays well-formed" {
  local proj="$BATS_TEST_TMPDIR/gitignore-no-nl"
  make_repo_with_remote "$proj"
  printf 'result' >"$proj/.gitignore" # no trailing newline

  run_in_dir "$proj" "$INIT_APP"
  assert_success

  # The pre-existing entry survives and the appended line is its own line.
  assert grep -qxF 'result' "$proj/.gitignore"
  assert_equal "$(grep -cxF '/.claude/skills/' "$proj/.gitignore")" "1"
}

@test "-h prints usage and exits 0 without writing" {
  local proj="$BATS_TEST_TMPDIR/help"
  make_repo_with_remote "$proj"

  run_in_dir "$proj" "$INIT_APP" -h
  assert_success
  assert_output --partial "Usage:"
  refute [ -e "$proj/skills-devshell/flake.nix" ]
}

@test "a sed-metacharacter repo name fails loud, no silent corruption" {
  # The dir basename carries an `&` (a sed replacement metacharacter). With no
  # remote, `repo` resolves to this name and must be rejected by validation.
  local proj="$BATS_TEST_TMPDIR/foo&bar"
  mkdir -p "$proj"
  ( cd "$proj" && git init -q -b main ) # no origin remote -> dir-name fallback

  run_in_dir "$proj" "$INIT_APP"
  assert_failure
  assert_output --partial "could not derive a safe repo name"
  # Nothing scaffolded.
  refute [ -e "$proj/skills-devshell/flake.nix" ]
}

@test "--dry-run on an existing file leaves it byte-identical" {
  local proj="$BATS_TEST_TMPDIR/dry-existing"
  make_repo_with_remote "$proj"
  mkdir -p "$proj/skills-devshell"
  printf 'stale\n' >"$proj/skills-devshell/flake.nix"
  local before
  before=$(cat "$proj/skills-devshell/flake.nix")

  run_in_dir "$proj" "$INIT_APP" --dry-run
  assert_success
  assert_equal "$(cat "$proj/skills-devshell/flake.nix")" "$before"
}

@test "--force --dry-run announces overwrite but writes nothing" {
  local proj="$BATS_TEST_TMPDIR/force-dry"
  make_repo_with_remote "$proj"
  mkdir -p "$proj/skills-devshell"
  printf 'stale\n' >"$proj/skills-devshell/flake.nix"
  local before
  before=$(cat "$proj/skills-devshell/flake.nix")

  run_in_dir "$proj" "$INIT_APP" --force --dry-run
  assert_success
  assert_output --partial "would overwrite"
  # Existing file unchanged despite the would-overwrite announcement.
  assert_equal "$(cat "$proj/skills-devshell/flake.nix")" "$before"
}

