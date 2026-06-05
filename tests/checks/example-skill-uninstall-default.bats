#!/usr/bin/env bats
# Inputs: INSTALL_APP, UNINSTALL_SKILL_APP — single-skill entrypoints.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "no-arg uninstall removes the flake's default skill" {
  run "$INSTALL_APP" "${scope_args[@]}"
  assert_success
  assert [ -L "$CUSTOM_TARGET/example-skill" ]

  run "$UNINSTALL_SKILL_APP" "${scope_args[@]}"
  assert_success

  refute [ -L "$CUSTOM_TARGET/example-skill" ]
  refute [ -e "$GCROOTS_DIR/claude-skill-example-skill" ]
  assert_equal \
    "$(jq '.skills | length' "$CUSTOM_TARGET/.agent-skill-flake-lock.json")" "0"
}
