#!/usr/bin/env bats
# Inputs: RECONCILE_A_APP — aggregate "coexist-a", owns alpha + beta.
#         RECONCILE_B_APP — aggregate "coexist-b", owns gamma.
#
# Scoped ownership: two aggregates sharing one target dir each declaratively
# own only their own slice. A's reconcile must never sweep B's gamma, and
# B's reconcile must never sweep A's alpha/beta — the property that keeps
# the marketplace helpers composable.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CUSTOM_TARGET"
}

@test "each aggregate sweeps only its own strays" {
  run "$RECONCILE_A_APP" "${scope_args[@]}"
  assert_success
  run "$RECONCILE_B_APP" "${scope_args[@]}"
  assert_success

  # Both aggregates' skills coexist in the one target.
  assert [ -L "$CUSTOM_TARGET/alpha" ]
  assert [ -L "$CUSTOM_TARGET/beta" ]
  assert [ -L "$CUSTOM_TARGET/gamma" ]

  # Re-running A converges its own slice (alpha, beta) but leaves gamma —
  # owned by coexist-b — untouched, even though gamma is not in A's set.
  run "$RECONCILE_A_APP" "${scope_args[@]}"
  assert_success
  refute_output --partial 'reconciled (sweep): '"$CUSTOM_TARGET"'/gamma'
  assert [ -L "$CUSTOM_TARGET/gamma" ]
  assert [ -L "$CUSTOM_TARGET/alpha" ]
  assert [ -L "$CUSTOM_TARGET/beta" ]

  # Symmetric: re-running B leaves A's alpha/beta untouched.
  run "$RECONCILE_B_APP" "${scope_args[@]}"
  assert_success
  refute_output --partial 'reconciled (sweep): '"$CUSTOM_TARGET"'/alpha'
  refute_output --partial 'reconciled (sweep): '"$CUSTOM_TARGET"'/beta'
  assert [ -L "$CUSTOM_TARGET/alpha" ]
  assert [ -L "$CUSTOM_TARGET/beta" ]
  assert [ -L "$CUSTOM_TARGET/gamma" ]
}
