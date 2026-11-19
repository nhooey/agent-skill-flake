#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP, CHECK_ALL_APP — aggregate entrypoints (alpha + beta).
#
# `check` reports each store link in a target that has no GC root of the
# target's own — its record of a shared root, or its flat root — and is
# silent with exit 0 when every link is rooted.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  TARGET_B="$BATS_TEST_TMPDIR/target-b"
}

check_in() {
  run "$CHECK_ALL_APP" --scope=custom --root="$1" --gcroots-dir="$GCROOTS_DIR"
}

# drop_shared_root <name> — remove the target's record for <name> and the
# shared root and anchor it used.
drop_shared_root() {
  local root
  root=$(gc_shared_root "$(gc_record_store_path "$1")")
  rm "$(gc_record "$1")" "$root" "$root.refs"
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
  drop_shared_root alpha

  check_in "$CUSTOM_TARGET"
  assert_failure 1
  assert_output --regexp "^unrooted: $CUSTOM_TARGET/alpha -> /nix/store/[^/]+: no GC root; expected claude-skills/targets/[0-9a-f]{12}/alpha$"
}

@test "a link rooted only through another target's record is reported as wrongly rooted" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}" alpha
  assert_success
  run "$INSTALL_ALL_APP" --scope=custom --root="$TARGET_B" --gcroots-dir="$GCROOTS_DIR" alpha
  assert_success
  local sp
  sp=$(gc_record_store_path alpha)
  rm "$(gc_record alpha)"

  check_in "$CUSTOM_TARGET"
  assert_failure 1
  assert_output --partial "wrongly rooted: $CUSTOM_TARGET/alpha -> /nix/store/"
  assert_output --partial "rooted by claude-skills/store/${sp##*/}, not claude-skills/targets/$(gc_root_tag "$CUSTOM_TARGET")/alpha"

  check_in "$TARGET_B"
  assert_success
  assert_output ''
}

@test "a legacy shared root doesn't count as the target's own" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}" alpha
  assert_success
  local store_path
  store_path=$(gc_record_store_path alpha)
  drop_shared_root alpha
  ln -s "$store_path" "$GCROOTS_DIR/claude-skill-alpha"

  check_in "$CUSTOM_TARGET"
  assert_failure 1
  assert_output --partial "rooted by claude-skill-alpha, not claude-skills/targets/$(gc_root_tag "$CUSTOM_TARGET")/alpha"
}

@test "the target's own flat root counts until it moves into a record" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}" alpha beta
  assert_success
  flatten_gc_roots

  check_in "$CUSTOM_TARGET"
  assert_success
  assert_output ''
}

@test "a store link the lock doesn't list is left out" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}" alpha
  assert_success
  ln -s "$(readlink "$CUSTOM_TARGET/alpha")" "$CUSTOM_TARGET/someone-elses"

  check_in "$CUSTOM_TARGET"
  assert_success
  assert_output ''
}
