#!/usr/bin/env bats
# Inputs: UNINSTALL_ALL_APP — aggregate uninstall entrypoint.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CLAUDE_SKILLS_DIR"
}

@test "uninstall refuses to touch an unmanaged entry" {
  mkdir -p "$CLAUDE_SKILLS_DIR/manual-skill"
  echo manual > "$CLAUDE_SKILLS_DIR/manual-skill/SKILL.md"

  run "$UNINSTALL_ALL_APP" manual-skill
  assert_failure
  assert_output --partial "not managed by"

  assert [ -d "$CLAUDE_SKILLS_DIR/manual-skill" ]
  assert [ -f "$CLAUDE_SKILLS_DIR/manual-skill/SKILL.md" ]
}
