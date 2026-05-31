#!/usr/bin/env bats
# Inputs: RECONCILE_FULL_APP   — union = base (alpha, beta) + src-gamma.
#         RECONCILE_REDUCED_APP — same appName "converge", source dropped,
#                                 so the union shrinks to alpha, beta.
#
# The regression test for the skills-git stray-leftover bug: a skill that
# leaves the declared union (here src-gamma, the prefixed source dropped
# from the aggregate) must be swept on the next reconcile, leaving exactly
# the new union — not the old one plus the new.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CUSTOM_TARGET"
}

@test "shrinking the declared union sweeps the dropped skill" {
  run "$RECONCILE_FULL_APP" "${scope_args[@]}"
  assert_success

  # Full union present: base skills + the prefixed source's skill.
  assert [ -L "$CUSTOM_TARGET/alpha" ]
  assert [ -L "$CUSTOM_TARGET/beta" ]
  assert [ -L "$CUSTOM_TARGET/src-gamma" ]
  assert [ -L "$GCROOTS_DIR/claude-skill-src-gamma" ]

  run "$RECONCILE_REDUCED_APP" "${scope_args[@]}"
  assert_success

  # The dropped skill and its GC root are gone; base survives.
  refute [ -e "$CUSTOM_TARGET/src-gamma" ]
  refute [ -e "$GCROOTS_DIR/claude-skill-src-gamma" ]
  assert [ -L "$CUSTOM_TARGET/alpha" ]
  assert [ -L "$CUSTOM_TARGET/beta" ]
  assert [ -f "$CUSTOM_TARGET/alpha/SKILL.md" ]
  assert [ -f "$CUSTOM_TARGET/beta/SKILL.md" ]
}
