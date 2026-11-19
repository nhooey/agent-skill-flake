#!/usr/bin/env bats
# Inputs: INSTALL_APP, REAP_SKILL_APP — single-skill entrypoints.
# The single-skill reap removes a managed entry whose store path is gone,
# keeps the live install and leaves unmanaged entries alone.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "single-skill reap removes a broken managed entry, keeps the live one" {
  run "$INSTALL_APP" "${scope_args[@]}"
  assert_success
  assert_store_symlink "$CUSTOM_TARGET/example-skill"

  # Managed-but-broken: a link into a store path that doesn't exist, with
  # this target's GC-root record for it.
  local bogus=/nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-bogus
  ln -sfn "$bogus/share/claude-skills/foo" "$CUSTOM_TARGET/foo"
  fake_gc_record foo "$bogus"

  mkdir -p "$CUSTOM_TARGET/manual-skill"
  echo manual > "$CUSTOM_TARGET/manual-skill/SKILL.md"

  run "$REAP_SKILL_APP" "${scope_args[@]}"
  assert_success

  refute [ -L "$CUSTOM_TARGET/foo" ]
  refute [ -e "$(gc_record foo)" ]

  assert_store_symlink "$CUSTOM_TARGET/example-skill"
  assert [ -f "$CUSTOM_TARGET/example-skill/SKILL.md" ]
  assert_gc_rooted example-skill
  assert [ -f "$CUSTOM_TARGET/manual-skill/SKILL.md" ]
}

@test "single-skill reap on a clean target changes nothing" {
  run "$INSTALL_APP" "${scope_args[@]}"
  assert_success
  local before
  before=$(snapshot_fs "$CUSTOM_TARGET" "$GCROOTS_DIR")

  run "$REAP_SKILL_APP" "${scope_args[@]}"
  assert_success
  assert_equal "$(snapshot_fs "$CUSTOM_TARGET" "$GCROOTS_DIR")" "$before"
}
