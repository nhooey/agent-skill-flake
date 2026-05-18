#!/usr/bin/env bats
# Inputs: PREVIEW_ALL_APP — aggregate preview entrypoint.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "aggregate preview is read-only and lists both skills" {
  local before after
  before=$(snapshot_fs "$HOME" "$CLAUDE_SKILLS_DIR")

  run "$PREVIEW_ALL_APP"
  assert_success

  after=$(snapshot_fs "$HOME" "$CLAUDE_SKILLS_DIR")
  assert_equal "$before" "$after"

  assert_output --partial "preview"
  assert_output --partial "Target directory"
  assert_output --partial "alpha"
  assert_output --partial "beta"
  assert_output --partial "2 skill(s) total"
}
