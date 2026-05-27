#!/usr/bin/env bats
# Inputs: UNINSTALL_ALL_APP — aggregate uninstall entrypoint.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CUSTOM_TARGET"
}

@test "uninstall refuses to touch an unmanaged entry" {
  mkdir -p "$CUSTOM_TARGET/manual-skill"
  echo manual > "$CUSTOM_TARGET/manual-skill/SKILL.md"

  run "$UNINSTALL_ALL_APP" "${scope_args[@]}" manual-skill
  assert_failure
  assert_output --partial "not managed by"

  assert [ -d "$CUSTOM_TARGET/manual-skill" ]
  assert [ -f "$CUSTOM_TARGET/manual-skill/SKILL.md" ]
}
