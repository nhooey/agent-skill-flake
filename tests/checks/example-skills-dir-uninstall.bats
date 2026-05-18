#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP, UNINSTALL_ALL_APP — aggregate entrypoints.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "uninstall one skill removes its 3 artifacts, leaves the other" {
  run "$INSTALL_ALL_APP"
  assert_success
  run "$UNINSTALL_ALL_APP" alpha
  assert_success

  local lock="$CLAUDE_SKILLS_DIR/.flake-skills-lock.json"

  refute [ -L "$CLAUDE_SKILLS_DIR/alpha" ]
  refute [ -e "$NIX_GCROOTS_DIR/claude-skill-alpha" ]
  assert_equal \
    "$(jq 'has("skills") and (.skills | has("alpha") | not)' "$lock")" "true"

  assert [ -L "$CLAUDE_SKILLS_DIR/beta" ]
  assert [ -L "$NIX_GCROOTS_DIR/claude-skill-beta" ]
  assert_equal "$(jq -r '.skills.beta.skillName' "$lock")" "beta"
}
