#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP, CHECK_ALL_APP — aggregate entrypoints (alpha + beta).
#
# `check` reports each store link in a target that has no GC root of the
# target's own, and is silent with exit 0 when every link is rooted.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  TARGET_B="$BATS_TEST_TMPDIR/target-b"
}

check_in() {
  run "$CHECK_ALL_APP" --scope=custom --root="$1" --gcroots-dir="$GCROOTS_DIR"
}

@test "a fully rooted target is silent and exits 0" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}" alpha beta
  assert_success
  ln -s "$BATS_TEST_TMPDIR" "$CUSTOM_TARGET/not-in-store"

  check_in "$CUSTOM_TARGET"
  assert_success
  assert_output ''
}

@test "a link with no root is reported as unrooted" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}" alpha beta
  assert_success
  rm "$(gc_root alpha)"

  check_in "$CUSTOM_TARGET"
  assert_failure 1
  assert_output --regexp "^unrooted: $CUSTOM_TARGET/alpha -> /nix/store/[^/]+: no GC root; expected claude-skill-[0-9a-f]{12}-alpha$"
}

@test "a link rooted only by another target's root is reported as wrongly rooted" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}" alpha
  assert_success
  run "$INSTALL_ALL_APP" --scope=custom --root="$TARGET_B" --gcroots-dir="$GCROOTS_DIR" alpha
  assert_success
  rm "$(gc_root alpha)"

  check_in "$CUSTOM_TARGET"
  assert_failure 1
  assert_output --partial "wrongly rooted: $CUSTOM_TARGET/alpha -> /nix/store/"
  assert_output --partial "rooted by $(basename "$(gc_root alpha "$TARGET_B")"), not $(basename "$(gc_root alpha)")"

  check_in "$TARGET_B"
  assert_success
  assert_output ''
}

@test "a legacy shared root doesn't count as the target's own" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}" alpha
  assert_success
  local root store_path
  root=$(gc_root alpha)
  store_path=$(readlink "$root")
  rm "$root"
  ln -s "$store_path" "$GCROOTS_DIR/claude-skill-alpha"

  check_in "$CUSTOM_TARGET"
  assert_failure 1
  assert_output --partial "rooted by claude-skill-alpha, not $(basename "$root")"
}

@test "a store link the lock doesn't list is left out" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}" alpha
  assert_success
  ln -s "$(readlink "$CUSTOM_TARGET/alpha")" "$CUSTOM_TARGET/someone-elses"

  check_in "$CUSTOM_TARGET"
  assert_success
  assert_output ''
}
