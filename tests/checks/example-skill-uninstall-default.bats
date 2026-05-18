#!/usr/bin/env bats
# Inputs: INSTALL_APP, UNINSTALL_SKILL_APP — single-skill entrypoints.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "no-arg uninstall removes the flake's default skill" {
  run "$INSTALL_APP"
  assert_success
  assert [ -L "$CLAUDE_SKILLS_DIR/example-skill" ]

  run "$UNINSTALL_SKILL_APP"
  assert_success

  refute [ -L "$CLAUDE_SKILLS_DIR/example-skill" ]
  refute [ -e "$NIX_GCROOTS_DIR/claude-skill-example-skill" ]
  assert_equal \
    "$(jq '.skills | length' "$CLAUDE_SKILLS_DIR/.flake-skills-lock.json")" "0"
}
