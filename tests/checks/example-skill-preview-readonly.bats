#!/usr/bin/env bats
# Inputs: PREVIEW_APP — single-skill preview entrypoint.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "preview is read-only and reports the skill" {
  local before after
  before=$(snapshot_fs "$HOME" "$CLAUDE_SKILLS_DIR")

  run "$PREVIEW_APP"
  assert_success

  after=$(snapshot_fs "$HOME" "$CLAUDE_SKILLS_DIR")
  assert_equal "$before" "$after"

  assert_output --partial "preview"
  assert_output --partial "Target directory"
  assert_output --partial "example-skill"
}
