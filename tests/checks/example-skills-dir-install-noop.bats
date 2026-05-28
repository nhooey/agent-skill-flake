#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP — aggregate install entrypoint (alpha + beta).
#
# Idempotency: a second invocation with everything already in place
# should print nothing per-skill. Partial breakage (deleted symlink or
# deleted GC root) should re-announce only the broken artifact.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "install: second invocation prints nothing when state is in sync" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}"
  assert_success
  assert_output --partial 'installed (symlink): '

  run "$INSTALL_ALL_APP" "${scope_args[@]}"
  assert_success
  refute_output --partial 'installed (symlink): '
  refute_output --partial 'GC root: '
}

@test "install: restoring a deleted target re-announces just that one" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}"
  assert_success

  rm "$CUSTOM_TARGET/alpha"

  run "$INSTALL_ALL_APP" "${scope_args[@]}"
  assert_success
  assert_output --partial 'installed (symlink): '"$CUSTOM_TARGET"'/alpha'
  refute_output --partial 'installed (symlink): '"$CUSTOM_TARGET"'/beta'
}

@test "install: re-announces only GC root when target is fine but GC root deleted" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}"
  assert_success

  rm "$GCROOTS_DIR/claude-skill-alpha"

  run "$INSTALL_ALL_APP" "${scope_args[@]}"
  assert_success
  assert_output --partial 'GC root: '"$GCROOTS_DIR"'/claude-skill-alpha'
  refute_output --partial 'GC root: '"$GCROOTS_DIR"'/claude-skill-beta'
  refute_output --partial 'installed (symlink): '
}
