#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP, PURGE_ALL_APP — aggregate entrypoints.
# Purge removes EVERY live lineage entry (no declared set, no names),
# while leaving unmanaged entries untouched.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CUSTOM_TARGET"
}

@test "purge --yes removes all live managed entries, spares unmanaged" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}"
  assert_success
  assert [ -L "$CUSTOM_TARGET/alpha" ]
  assert [ -L "$CUSTOM_TARGET/beta" ]

  # Unmanaged entry — must NOT be touched.
  mkdir -p "$CUSTOM_TARGET/manual-skill"
  echo manual > "$CUSTOM_TARGET/manual-skill/SKILL.md"

  run "$PURGE_ALL_APP" "${scope_args[@]}" --yes
  assert_success
  assert_output --partial "2 entr"

  local lock="$CUSTOM_TARGET/.flake-skills-lock.json"
  for name in alpha beta; do
    refute [ -L "$CUSTOM_TARGET/$name" ]
    refute [ -e "$GCROOTS_DIR/claude-skill-$name" ]
    assert_equal "$(jq --arg n "$name" '.skills | has($n)' "$lock")" "false"
  done

  assert [ -d "$CUSTOM_TARGET/manual-skill" ]
  assert [ -f "$CUSTOM_TARGET/manual-skill/SKILL.md" ]
}
