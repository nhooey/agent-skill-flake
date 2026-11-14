#!/usr/bin/env bats
# Inputs: REAP_ALL_APP, RECONCILE_ALL_APP — aggregate entrypoints;
#         PRE_MANAGED_BY_LOCK — a lock from before installs recorded
#         `managedBy`: 4 entries under an old appName whose store paths
#         were garbage-collected.
#
# A broken link whose lock entry has no `managedBy`, pointing into that
# entry's missing claude-skill store path, counts as ours for reap and
# for reconcile's sweep, though no GC root names it.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CUSTOM_TARGET"
  cp "$PRE_MANAGED_BY_LOCK" "$CUSTOM_TARGET/.agent-skill-flake-lock.json"
  chmod u+w "$CUSTOM_TARGET/.agent-skill-flake-lock.json"
  old_names=()
  local name sp
  while IFS=$'\t' read -r name sp; do
    refute [ -e "$sp" ]
    ln -s "$sp/share/claude-skills/$name" "$CUSTOM_TARGET/$name"
    old_names+=("$name")
  done < <(jq -r '.skills | to_entries[] | "\(.key)\t\(.value.storePath)"' "$CUSTOM_TARGET/.agent-skill-flake-lock.json")
  assert_equal "${#old_names[@]}" 4
}


# add_entry <name> <lock-json> <link-target> — one more lock entry and link.
add_entry() {
  local f="$CUSTOM_TARGET/.agent-skill-flake-lock.json"
  jq --arg n "$1" --argjson v "$2" '.skills[$n] = $v' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  ln -s "$3" "$CUSTOM_TARGET/$1"
}

@test "reap removes broken pre-managedBy entries and their lock entries" {
  run "$REAP_ALL_APP" "${scope_args[@]}"
  assert_success
  local name
  for name in "${old_names[@]}"; do
    refute [ -L "$CUSTOM_TARGET/$name" ]
    assert_output --partial "reaped: $CUSTOM_TARGET/$name"
  done
  assert_equal "$(jq '.skills | length' "$CUSTOM_TARGET/.agent-skill-flake-lock.json")" 0
}

@test "reap leaves broken entries the lock rule doesn't cover" {
  local gone=/nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-claude-skill-kept-0.1.0
  # Recorded managedBy: someone else's lineage, and no GC root names it.
  add_entry with-managed-by \
    "{\"storePath\": \"$gone\", \"managedBy\": \"github:someone/else\"}" \
    "$gone/share/claude-skills/with-managed-by"
  # The link points elsewhere than the entry's storePath.
  add_entry other-target "{\"storePath\": \"$gone\"}" \
    /nix/store/yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy-claude-skill-other-0.1.0/share/claude-skills/other-target
  # The storePath isn't a claude-skill path.
  add_entry not-a-skill-path \
    '{"storePath": "/nix/store/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx-hm_files"}' \
    /nix/store/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx-hm_files/not-a-skill-path

  run "$REAP_ALL_APP" "${scope_args[@]}"
  assert_success
  assert [ -L "$CUSTOM_TARGET/with-managed-by" ]
  assert [ -L "$CUSTOM_TARGET/other-target" ]
  assert [ -L "$CUSTOM_TARGET/not-a-skill-path" ]
}

@test "reconcile sweeps broken pre-managedBy entries of another appName" {
  run "$RECONCILE_ALL_APP" "${scope_args[@]}"
  assert_success
  local name
  for name in "${old_names[@]}"; do
    refute [ -L "$CUSTOM_TARGET/$name" ]
    assert_output --partial "reconciled (sweep, broken): $CUSTOM_TARGET/$name"
    assert_equal "$(jq --arg n "$name" '.skills | has($n)' "$CUSTOM_TARGET/.agent-skill-flake-lock.json")" false
  done
  assert [ -f "$CUSTOM_TARGET/alpha/SKILL.md" ]
}
