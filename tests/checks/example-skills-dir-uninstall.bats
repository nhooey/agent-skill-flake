#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP, UNINSTALL_ALL_APP — aggregate entrypoints.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "uninstall one skill removes its 3 artifacts, leaves the other" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}"
  assert_success
  run "$UNINSTALL_ALL_APP" "${scope_args[@]}" alpha
  assert_success

  local lock="$CUSTOM_TARGET/.flake-skills-lock.json"

  refute [ -L "$CUSTOM_TARGET/alpha" ]
  refute [ -e "$GCROOTS_DIR/claude-skill-alpha" ]
  assert_equal \
    "$(jq 'has("skills") and (.skills | has("alpha") | not)' "$lock")" "true"

  assert [ -L "$CUSTOM_TARGET/beta" ]
  assert [ -L "$GCROOTS_DIR/claude-skill-beta" ]
  assert_equal "$(jq -r '.skills.beta.skillName' "$lock")" "beta"
}
