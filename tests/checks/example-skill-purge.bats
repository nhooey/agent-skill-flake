#!/usr/bin/env bats
# Inputs: INSTALL_APP, PURGE_SKILL_APP — single-skill entrypoints.
# The single-skill purge removes the live install, its GC root and its
# lock entry, and leaves unmanaged entries alone.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "single-skill purge --yes removes the live install, spares unmanaged" {
  run "$INSTALL_APP" "${scope_args[@]}"
  assert_success
  assert_store_symlink "$CUSTOM_TARGET/example-skill"
  assert [ -L "$(gc_root example-skill)" ]

  mkdir -p "$CUSTOM_TARGET/manual-skill"
  echo manual > "$CUSTOM_TARGET/manual-skill/SKILL.md"

  run "$PURGE_SKILL_APP" "${scope_args[@]}" --yes
  assert_success

  refute [ -L "$CUSTOM_TARGET/example-skill" ]
  refute [ -e "$(gc_root example-skill)" ]
  assert_equal \
    "$(jq '.skills | has("example-skill")' "$CUSTOM_TARGET/.agent-skill-flake-lock.json")" \
    "false"
  assert [ -f "$CUSTOM_TARGET/manual-skill/SKILL.md" ]
}

@test "single-skill purge --dry-run changes nothing" {
  run "$INSTALL_APP" "${scope_args[@]}"
  assert_success
  local before
  before=$(snapshot_fs "$CUSTOM_TARGET" "$GCROOTS_DIR")

  run "$PURGE_SKILL_APP" "${scope_args[@]}" --dry-run
  assert_success
  assert_output --partial "example-skill"
  assert_equal "$(snapshot_fs "$CUSTOM_TARGET" "$GCROOTS_DIR")" "$before"
}
