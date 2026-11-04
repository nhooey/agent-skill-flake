#!/usr/bin/env bats
# Inputs: RECONCILE_PREFS_APP   — appName "prefs": alpha, beta, and
#                                 alpha's preferences declared.
#         RECONCILE_DROPPED_APP — same appName, the preferences dropped.
#         PURGE_APP             — the same aggregate's purge.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CUSTOM_TARGET"
  link="$CUSTOM_TARGET/alpha.preferences.md"
  lock="$CUSTOM_TARGET/.agent-skill-flake-lock.json"
}

@test "declared preferences are linked from the store, GC-rooted and locked" {
  run "$RECONCILE_PREFS_APP" "${scope_args[@]}"
  assert_success
  assert_output --partial "reconciled (preferences): $link"
  assert_store_symlink "$link"
  assert_equal "$(cat "$link")" "- Delete local branch: yes"
  assert [ -L "$GCROOTS_DIR/claude-skill-alpha.preferences.md" ]
  assert_equal "$(jq -r '.preferences["alpha.preferences.md"].installedBy' "$lock")" "prefs"

  # A second reconcile changes nothing and says nothing about them.
  run "$RECONCILE_PREFS_APP" "${scope_args[@]}"
  assert_success
  refute_output --partial "reconciled (preferences)"
}

@test "dropping the preferences sweeps the link, its GC root and its lock entry" {
  run "$RECONCILE_PREFS_APP" "${scope_args[@]}"
  assert_success
  run "$RECONCILE_DROPPED_APP" "${scope_args[@]}"
  assert_success
  assert_output --partial "reconciled (sweep): $link"
  refute [ -e "$link" ]
  refute [ -e "$GCROOTS_DIR/claude-skill-alpha.preferences.md" ]
  assert_equal "$(jq -r 'has("preferences")' "$lock")" "false"
  assert [ -L "$CUSTOM_TARGET/alpha" ]
}

@test "a project's own preferences file is left alone and never locked" {
  printf -- '- Delete local branch: no\n' >"$link"
  run "$RECONCILE_PREFS_APP" "${scope_args[@]}"
  assert_success
  assert_output --partial "is the project's own file"
  refute [ -L "$link" ]
  assert_equal "$(cat "$link")" "- Delete local branch: no"
  assert_equal "$(jq -r 'has("preferences")' "$lock")" "false"

  # Nor does a reconcile without them remove it.
  run "$RECONCILE_DROPPED_APP" "${scope_args[@]}"
  assert_success
  assert [ -f "$link" ]
}

@test "purge removes a preferences link with the skills" {
  run "$RECONCILE_PREFS_APP" "${scope_args[@]}"
  assert_success
  run "$PURGE_APP" "${scope_args[@]}" --yes
  assert_success
  assert_output --partial "purged: $link"
  refute [ -e "$link" ]
  refute [ -e "$CUSTOM_TARGET/alpha" ]
}
