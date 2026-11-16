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
  assert [ -L "$(gc_root alpha.preferences.md)" ]
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
  refute [ -e "$(gc_root alpha.preferences.md)" ]
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

@test "a project's file put in place of a declared link survives the reconcile that drops it" {
  run "$RECONCILE_PREFS_APP" "${scope_args[@]}"
  assert_success
  # As a checkout of a commit that tracks the file writes it over the
  # ignored link: the lock still records the link as this flake's.
  rm "$link"
  printf -- '- Delete local branch: no\n' >"$link"

  run "$RECONCILE_DROPPED_APP" "${scope_args[@]}"
  assert_success
  assert_output --partial "kept: $link"
  refute_output --partial "reconciled (sweep): $link"
  assert [ -f "$link" ]
  refute [ -L "$link" ]
  assert_equal "$(cat "$link")" "- Delete local branch: no"
  refute [ -e "$(gc_root alpha.preferences.md)" ]
  assert_equal "$(jq -r 'has("preferences")' "$lock")" "false"
}

@test "preferences files for installed and uninstalled skills survive; a stale link is swept" {
  run "$RECONCILE_PREFS_APP" "${scope_args[@]}"
  assert_success
  printf -- '- Push mode: 2\n' >"$CUSTOM_TARGET/beta.preferences.md"
  printf -- '- Push mode: 2\n' >"$CUSTOM_TARGET/not-installed.preferences.md"

  run "$RECONCILE_DROPPED_APP" "${scope_args[@]}"
  assert_success
  assert_output --partial "reconciled (sweep): $link"
  refute [ -e "$link" ]
  assert [ -L "$CUSTOM_TARGET/beta" ]
  assert_equal "$(cat "$CUSTOM_TARGET/beta.preferences.md")" "- Push mode: 2"
  assert_equal "$(cat "$CUSTOM_TARGET/not-installed.preferences.md")" "- Push mode: 2"

  run "$RECONCILE_PREFS_APP" "${scope_args[@]}"
  assert_success
  assert [ -f "$CUSTOM_TARGET/beta.preferences.md" ]
  assert [ -f "$CUSTOM_TARGET/not-installed.preferences.md" ]
}

@test "a skill's path holding the project's own directory is not replaced" {
  mkdir -p "$CUSTOM_TARGET/beta"
  printf 'mine\n' >"$CUSTOM_TARGET/beta/SKILL.md"
  run "$RECONCILE_PREFS_APP" "${scope_args[@]}"
  assert_success
  assert_output --partial "$CUSTOM_TARGET/beta is the project's own file"
  refute [ -L "$CUSTOM_TARGET/beta" ]
  assert_equal "$(cat "$CUSTOM_TARGET/beta/SKILL.md")" "mine"
  assert_equal "$(jq -r '.skills | has("beta")' "$lock")" "false"
  assert [ -L "$CUSTOM_TARGET/alpha" ]
}
