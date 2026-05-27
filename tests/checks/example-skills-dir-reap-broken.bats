#!/usr/bin/env bats
# Inputs: REAP_ALL_APP — aggregate reap entrypoint.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CUSTOM_TARGET"
}

@test "reap removes managed-but-broken entry, spares unmanaged" {
  # Forge a managed-but-broken entry: symlink to a non-existent store
  # path + same-named GC root (the naming-convention fallback).
  local bogus=/nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-bogus
  ln -sfn "$bogus/share/claude-skills/foo" "$CUSTOM_TARGET/foo"
  ln -sfn "$bogus" "$GCROOTS_DIR/claude-skill-foo"

  # Unmanaged entry — must NOT be touched.
  mkdir -p "$CUSTOM_TARGET/manual-skill"
  echo manual > "$CUSTOM_TARGET/manual-skill/SKILL.md"

  run "$REAP_ALL_APP" "${scope_args[@]}"
  assert_success

  refute [ -L "$CUSTOM_TARGET/foo" ]
  refute [ -e "$GCROOTS_DIR/claude-skill-foo" ]

  assert [ -d "$CUSTOM_TARGET/manual-skill" ]
  assert [ -f "$CUSTOM_TARGET/manual-skill/SKILL.md" ]
}
