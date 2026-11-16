#!/usr/bin/env bats
# Inputs: RECONCILE_APP, REAP_APP, PURGE_APP — mkDevshellSkillsFlake's apps
#         over a single combination of fixtureAll (alpha, beta).
#         ALPHA_PKG — the union's re-exposed agent-skill-alpha package.
# The apps the dev-shell wiring calls by name do what their names say:
# reconcile installs the union, reap prunes only broken entries, purge
# removes the whole set.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "the re-exposed per-skill package is the alpha skill" {
  assert_equal \
    "$(jq -r .skillName "$ALPHA_PKG/share/claude-skills/alpha/.agent-skill-flake-managed.json")" \
    "alpha"
}

@test "reconcile installs the union, reap prunes broken, purge removes all" {
  run "$RECONCILE_APP" "${scope_args[@]}"
  assert_success
  assert_store_symlink "$CUSTOM_TARGET/alpha"
  assert_store_symlink "$CUSTOM_TARGET/beta"

  local bogus=/nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-bogus
  ln -sfn "$bogus/share/claude-skills/foo" "$CUSTOM_TARGET/foo"
  ln -sfn "$bogus" "$(gc_root foo)"

  run "$REAP_APP" "${scope_args[@]}"
  assert_success
  refute [ -L "$CUSTOM_TARGET/foo" ]
  assert_store_symlink "$CUSTOM_TARGET/alpha"
  assert_store_symlink "$CUSTOM_TARGET/beta"

  run "$PURGE_APP" "${scope_args[@]}" --yes
  assert_success
  refute [ -L "$CUSTOM_TARGET/alpha" ]
  refute [ -L "$CUSTOM_TARGET/beta" ]
  refute [ -e "$(gc_root alpha)" ]
  refute [ -e "$(gc_root beta)" ]
}
