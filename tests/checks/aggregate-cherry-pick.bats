#!/usr/bin/env bats
# Inputs: RECONCILE_VERBATIM_APP — aggregate "cherrypick": a source exposing
#                                  alpha + beta with only `alpha` cherry-picked.
#         RECONCILE_PREFIXED_APP — same, prefix "px", so the kept skill lands
#                                  as `px-alpha` and `px-beta` never exists.
#
# The per-source `skills` filter the reconcile rewrite silently ignored: a
# cherry-pick must install exactly the named skill and never its sibling,
# whether the source is merged verbatim or re-prefixed.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CUSTOM_TARGET"
}

@test "verbatim cherry-pick installs only the selected skill" {
  run "$RECONCILE_VERBATIM_APP" "${scope_args[@]}"
  assert_success

  # The cherry-picked skill lands; its dropped sibling never does.
  assert [ -L "$CUSTOM_TARGET/alpha" ]
  assert [ -f "$CUSTOM_TARGET/alpha/SKILL.md" ]
  refute [ -e "$CUSTOM_TARGET/beta" ]
  refute [ -e "$GCROOTS_DIR/claude-skill-beta" ]
}

@test "prefixed cherry-pick installs only the selected skill" {
  run "$RECONCILE_PREFIXED_APP" "${scope_args[@]}"
  assert_success

  # The kept skill lands under its prefix; the dropped sibling does not, and
  # neither skill appears under its bare upstream name.
  assert [ -L "$CUSTOM_TARGET/px-alpha" ]
  assert [ -f "$CUSTOM_TARGET/px-alpha/SKILL.md" ]
  refute [ -e "$CUSTOM_TARGET/px-beta" ]
  refute [ -e "$CUSTOM_TARGET/alpha" ]
  refute [ -e "$CUSTOM_TARGET/beta" ]
}
