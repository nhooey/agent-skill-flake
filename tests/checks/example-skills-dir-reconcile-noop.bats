#!/usr/bin/env bats
# Inputs: RECONCILE_ALL_APP — aggregate reconcile entrypoint (alpha + beta).
#
# Idempotency mirror of install-noop: a second reconcile with everything
# already in place should print no per-skill `reconciled (install): …`
# lines. The trailing one-line summary is intentionally kept (per the
# silent-idempotent-install-reconcile plan §"Trailing summary"), so the
# tests only refute the per-skill lines, not the whole output.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "reconcile: second invocation skips the per-skill install lines" {
  run "$RECONCILE_ALL_APP" "${scope_args[@]}"
  assert_success
  assert_output --partial 'reconciled (install): '

  run "$RECONCILE_ALL_APP" "${scope_args[@]}"
  assert_success
  refute_output --partial 'reconciled (install): '
}

@test "reconcile: restoring a deleted target re-announces just that one" {
  run "$RECONCILE_ALL_APP" "${scope_args[@]}"
  assert_success

  rm "$CUSTOM_TARGET/alpha"

  run "$RECONCILE_ALL_APP" "${scope_args[@]}"
  assert_success
  assert_output --partial 'reconciled (install): '"$CUSTOM_TARGET"'/alpha'
  refute_output --partial 'reconciled (install): '"$CUSTOM_TARGET"'/beta'
}

@test "reconcile: a deleted GC root is restored quietly (no per-skill line)" {
  # The reconcile install loop's GC-root branch doesn't emit a
  # `GC root: …` line even on the rewrite (unlike install.sh) — so
  # this test asserts that the rewrite happens (symlink restored)
  # without any per-skill `reconciled (install): …` chatter.
  run "$RECONCILE_ALL_APP" "${scope_args[@]}"
  assert_success

  rm "$GCROOTS_DIR/claude-skill-alpha"

  run "$RECONCILE_ALL_APP" "${scope_args[@]}"
  assert_success
  refute_output --partial 'reconciled (install): '
  assert [ -L "$GCROOTS_DIR/claude-skill-alpha" ]
}
