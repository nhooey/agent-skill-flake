#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP, PURGE_ALL_APP — aggregate entrypoints.
# --dry-run lists what would go and changes nothing; a non-interactive
# run without --yes/--dry-run refuses rather than touch anything.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CUSTOM_TARGET"
}

@test "purge --dry-run reports would-remove and changes nothing" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}"
  assert_success

  run "$PURGE_ALL_APP" "${scope_args[@]}" --dry-run
  assert_success
  assert_output --partial "would purge"
  assert_output --partial "would be purged"

  # Untouched: both skills and their GC roots survive a dry run.
  assert [ -L "$CUSTOM_TARGET/alpha" ]
  assert [ -L "$CUSTOM_TARGET/beta" ]
  assert [ -L "$GCROOTS_DIR/claude-skill-alpha" ]
  assert [ -L "$GCROOTS_DIR/claude-skill-beta" ]
}

@test "purge refuses non-interactively without --yes" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}"
  assert_success

  # stdin is not a tty under the build sandbox; no --yes/--dry-run → refuse.
  run "$PURGE_ALL_APP" "${scope_args[@]}"
  assert_failure
  assert_output --partial "refusing to purge non-interactively"

  assert [ -L "$CUSTOM_TARGET/alpha" ]
  assert [ -L "$CUSTOM_TARGET/beta" ]
}
