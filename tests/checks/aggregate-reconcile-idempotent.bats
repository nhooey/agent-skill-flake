#!/usr/bin/env bats
# Inputs: RECONCILE_FULL_APP — combined reconcile over the union.
#
# Idempotence mirror of example-skills-dir-reconcile-noop, at the aggregate
# level: a second combined reconcile with everything already in place prints
# no per-skill `reconciled (install): …` lines. The trailing one-line
# summary is intentionally kept, so this only refutes the per-skill lines.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CUSTOM_TARGET"
}

@test "second combined reconcile skips the per-skill install lines" {
  run "$RECONCILE_FULL_APP" "${scope_args[@]}"
  assert_success
  assert_output --partial 'reconciled (install): '

  run "$RECONCILE_FULL_APP" "${scope_args[@]}"
  assert_success
  refute_output --partial 'reconciled (install): '
}
