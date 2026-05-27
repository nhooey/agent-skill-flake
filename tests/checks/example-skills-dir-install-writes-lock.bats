#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP — aggregate install entrypoint.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "install writes a lock entry per skill with full provenance" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}"
  assert_success

  local lock="$CUSTOM_TARGET/.flake-skills-lock.json"
  assert [ -f "$lock" ]

  assert_equal "$(jq -r '.schemaVersion' "$lock")" "1"
  assert_equal "$(jq -r '.skills | keys | sort | join(",")' "$lock")" "alpha,beta"

  local s field store_path
  for s in alpha beta; do
    for field in managedBy managedByRev managedByDirty managedByNarHash \
                 skillName version storePath installedAt; do
      assert_equal \
        "$(jq -r --arg s "$s" --arg f "$field" '.skills[$s] | has($f)' "$lock")" \
        "true"
    done
    store_path=$(jq -r --arg s "$s" '.skills[$s].storePath' "$lock")
    assert_equal "${store_path:0:11}" "/nix/store/"
  done
}
