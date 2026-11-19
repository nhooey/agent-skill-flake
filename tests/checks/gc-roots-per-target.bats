#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP, UNINSTALL_ALL_APP, REAP_ALL_APP, PURGE_ALL_APP,
#         RECONCILE_ALL_APP, CHECK_ALL_APP — aggregate entrypoints
#         (alpha + beta).
#
# Identical builds share one GC root, keyed by store path, and every
# install target keeps its own record per skill, a hard link of the root's
# anchor. A root goes only with the last record using it, so installing or
# uninstalling in one target never unroots another target's link.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  TARGET_A="$BATS_TEST_TMPDIR/target-a"
  TARGET_B="$BATS_TEST_TMPDIR/target-b"
}

# app_in <app> <target> [args...] — run <app> against custom root <target>.
app_in() {
  local app=$1 target=$2
  shift 2
  run "$app" --scope=custom --root="$target" --gcroots-dir="$GCROOTS_DIR" "$@"
}

# anchor_links <store-path> -> the link count of <store-path>'s anchor:
# one more than the records using its root.
anchor_links() {
  stat -c %h "$(gc_shared_root "$1").refs"
}

@test "two targets installing the same skill share one root, with a record each" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  app_in "$INSTALL_ALL_APP" "$TARGET_B" alpha
  assert_success

  assert_gc_rooted alpha "$TARGET_A"
  assert_gc_rooted alpha "$TARGET_B"
  local sp
  sp=$(gc_record_store_path alpha "$TARGET_A")
  assert_equal "$(gc_record_store_path alpha "$TARGET_B")" "$sp"
  assert_equal "$(anchor_links "$sp")" 3
  assert_equal "$(find "$GCROOTS_DIR" -type l -lname '/nix/store/*' | wc -l)" 1
  refute [ -e "$GCROOTS_DIR/claude-skill-alpha" ]
  refute [ -e "$(flat_gc_root alpha "$TARGET_A")" ]
}

@test "uninstalling from one target leaves the root the other target's record uses" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  app_in "$INSTALL_ALL_APP" "$TARGET_B" alpha
  assert_success

  app_in "$UNINSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success

  refute [ -e "$TARGET_A/alpha" ]
  refute [ -e "$(gc_record alpha "$TARGET_A")" ]
  assert [ -f "$TARGET_B/alpha/SKILL.md" ]
  assert_gc_rooted alpha "$TARGET_B"
  assert_equal "$(anchor_links "$(gc_record_store_path alpha "$TARGET_B")")" 2
}

@test "a shared root goes with the last record using it" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha beta
  assert_success
  app_in "$INSTALL_ALL_APP" "$TARGET_B" alpha
  assert_success
  local alpha_sp beta_sp
  alpha_sp=$(gc_record_store_path alpha "$TARGET_A")
  beta_sp=$(gc_record_store_path beta "$TARGET_A")

  app_in "$UNINSTALL_ALL_APP" "$TARGET_A" alpha beta
  assert_success
  refute [ -L "$(gc_shared_root "$beta_sp")" ]
  refute [ -e "$(gc_shared_root "$beta_sp").refs" ]
  assert_equal "$(readlink "$(gc_shared_root "$alpha_sp")")" "$alpha_sp"

  app_in "$UNINSTALL_ALL_APP" "$TARGET_B" alpha
  assert_success
  refute [ -L "$(gc_shared_root "$alpha_sp")" ]
  refute [ -e "$(gc_shared_root "$alpha_sp").refs" ]
  assert_equal "$(find "$GCROOTS_DIR" -type l -lname '/nix/store/*' | wc -l)" 0
}

@test "install and reconcile record the target dir beside its records" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  assert_equal "$(readlink "$(gc_root_record "$TARGET_A")")" "$(realpath -m -- "$TARGET_A")"

  app_in "$RECONCILE_ALL_APP" "$TARGET_B"
  assert_success
  assert_equal "$(readlink "$(gc_root_record "$TARGET_B")")" "$(realpath -m -- "$TARGET_B")"
}

@test "reap drops the records of an install target that no longer exists" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha beta
  assert_success
  app_in "$INSTALL_ALL_APP" "$TARGET_B" alpha
  assert_success
  local alpha_sp beta_sp
  alpha_sp=$(gc_record_store_path alpha "$TARGET_B")
  beta_sp=$(gc_record_store_path beta "$TARGET_A")

  # A worktree removed with its skills dir leaves records that still point
  # at live store paths.
  rm -r "$TARGET_A"

  app_in "$REAP_ALL_APP" "$TARGET_B"
  assert_success
  assert_output --partial "reaped GC root (install target gone): $(gc_record alpha "$TARGET_A")"
  assert_output --partial "reaped GC root (no record left): $(gc_shared_root "$beta_sp")"
  refute [ -e "$(gc_record alpha "$TARGET_A")" ]
  refute [ -e "$(gc_record beta "$TARGET_A")" ]
  refute [ -L "$(gc_root_record "$TARGET_A")" ]
  refute [ -L "$(gc_shared_root "$beta_sp")" ]
  assert_gc_rooted alpha "$TARGET_B"
  assert [ -L "$(gc_root_record "$TARGET_B")" ]
  assert [ -d "$alpha_sp" ]
}

@test "reap keeps the records of a target that has no record of its dir" {
  # The tag alone can't say whether the dir is gone, so reap leaves them.
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  rm "$(gc_root_record "$TARGET_A")"
  rm -r "$TARGET_A"

  app_in "$REAP_ALL_APP" "$TARGET_B"
  assert_success
  assert_gc_rooted alpha "$TARGET_A"
}

@test "a target keeps the records of its current and previous builds only" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha beta
  assert_success
  local rec alpha_sp beta_sp older="$BATS_TEST_TMPDIR/older-build"
  rec=$(gc_record alpha "$TARGET_A")
  alpha_sp=$(gc_record_store_path alpha "$TARGET_A")
  beta_sp=$(gc_record_store_path beta "$TARGET_A")
  # Stand-ins for alpha's last build (beta's store path) and the one
  # before it (a dir that exists, as a store path would).
  mkdir -p "$older"
  fake_gc_record alpha.previous "$older" "$TARGET_A"
  fake_gc_record alpha "$beta_sp" "$TARGET_A"

  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  assert_equal "$(cat "$rec")" "$alpha_sp"
  assert_equal "$(cat "$rec.previous")" "$beta_sp"
  assert [ "$rec.previous" -ef "$(gc_shared_root "$beta_sp").refs" ]
  refute [ -L "$(gc_shared_root "$older")" ]
  refute [ -e "$(gc_shared_root "$older").refs" ]

  # Reinstalling the same build moves nothing.
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  refute_output --partial 'GC root: '
  assert_equal "$(cat "$rec.previous")" "$beta_sp"
}

@test "reap drops a previous-build record whose current record is gone" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha beta
  assert_success
  local alpha_sp beta_sp
  alpha_sp=$(gc_record_store_path alpha "$TARGET_A")
  beta_sp=$(gc_record_store_path beta "$TARGET_A")
  fake_gc_record alpha.previous "$beta_sp" "$TARGET_A"
  fake_gc_record beta.previous "$alpha_sp" "$TARGET_A"
  rm "$(gc_record beta "$TARGET_A")"

  app_in "$REAP_ALL_APP" "$TARGET_A"
  assert_success
  assert_output --partial "reaped GC root (previous build, current root gone): $(gc_record beta.previous "$TARGET_A")"
  refute [ -e "$(gc_record beta.previous "$TARGET_A")" ]
  assert [ -f "$(gc_record alpha.previous "$TARGET_A")" ]
  assert_equal "$(jq -r '.skills.beta.storePath' "$TARGET_A/.agent-skill-flake-lock.json")" "$beta_sp"
}

@test "uninstall removes the previous-build record with the current one" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha beta
  assert_success
  local older="$BATS_TEST_TMPDIR/older-build"
  mkdir -p "$older"
  fake_gc_record alpha.previous "$older" "$TARGET_A"

  app_in "$UNINSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  refute [ -e "$(gc_record alpha "$TARGET_A")" ]
  refute [ -e "$(gc_record alpha.previous "$TARGET_A")" ]
  refute [ -L "$(gc_shared_root "$older")" ]
}

@test "reconcile moves the build it replaces to the previous-build record" {
  app_in "$RECONCILE_ALL_APP" "$TARGET_A"
  assert_success
  local rec alpha_sp beta_sp
  rec=$(gc_record alpha "$TARGET_A")
  alpha_sp=$(cat "$rec")
  beta_sp=$(gc_record_store_path beta "$TARGET_A")
  fake_gc_record alpha "$beta_sp" "$TARGET_A"

  app_in "$RECONCILE_ALL_APP" "$TARGET_A"
  assert_success
  assert_equal "$(cat "$rec")" "$alpha_sp"
  assert_equal "$(cat "$rec.previous")" "$beta_sp"
}

@test "reaping a root whose build is gone drops its records and leaves the lock alone" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  local lock="$TARGET_A/.agent-skill-flake-lock.json" before
  local gone=/nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-gone
  fake_gc_record alpha.previous "$gone" "$TARGET_A"
  before=$(jq -c '.skills.alpha' "$lock")

  app_in "$REAP_ALL_APP" "$TARGET_A"
  assert_success
  assert_output --partial "reaped GC root (target gone): $(gc_record alpha.previous "$TARGET_A")"
  assert_output --partial "reaped GC root (target gone): $(gc_shared_root "$gone")"
  refute [ -e "$(gc_record alpha.previous "$TARGET_A")" ]
  refute [ -L "$(gc_shared_root "$gone")" ]
  assert_gc_rooted alpha "$TARGET_A"
  assert_equal "$(jq -c '.skills.alpha' "$lock")" "$before"
}

@test "a previous-build record doesn't supersede a legacy root" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha beta
  assert_success
  local legacy="$GCROOTS_DIR/claude-skill-alpha" beta_sp
  beta_sp=$(gc_record_store_path beta "$TARGET_A")
  # The legacy root's store path is only some target's previous build,
  # which its next rebuild moves on from.
  fake_gc_record alpha.previous "$beta_sp" "$TARGET_A"
  rm "$(gc_record beta "$TARGET_A")"
  ln -s "$beta_sp" "$legacy"

  app_in "$REAP_ALL_APP" "$TARGET_A"
  assert_success
  assert_equal "$(readlink "$legacy")" "$beta_sp"
}

@test "purge drops a gone target's records, and its dry run only lists them" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  app_in "$INSTALL_ALL_APP" "$TARGET_B" alpha
  assert_success
  rm -r "$TARGET_A"

  app_in "$PURGE_ALL_APP" "$TARGET_B" --dry-run
  assert_success
  assert_output --partial "would purge GC root (install target gone): $(gc_record alpha "$TARGET_A")"
  assert [ -f "$(gc_record alpha "$TARGET_A")" ]

  app_in "$PURGE_ALL_APP" "$TARGET_B" --yes
  assert_success
  refute [ -e "$(gc_record alpha "$TARGET_A")" ]
  refute [ -L "$(gc_root_record "$TARGET_A")" ]
}

@test "a legacy root covered only by a gone target's record is kept" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  local store_path legacy="$GCROOTS_DIR/claude-skill-alpha"
  store_path=$(gc_record_store_path alpha "$TARGET_A")
  ln -s "$store_path" "$legacy"
  rm -r "$TARGET_A"

  app_in "$REAP_ALL_APP" "$TARGET_B"
  assert_success
  refute [ -e "$(gc_record alpha "$TARGET_A")" ]
  assert_equal "$(readlink "$legacy")" "$store_path"
}

@test "a target reached through a symlink shares the resolved dir's records" {
  mkdir -p "$TARGET_A"
  ln -s "$TARGET_A" "$BATS_TEST_TMPDIR/target-a-link"

  app_in "$INSTALL_ALL_APP" "$BATS_TEST_TMPDIR/target-a-link" alpha
  assert_success
  assert_gc_rooted alpha "$TARGET_A"

  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  refute_output --partial 'GC root: '
}

@test "a legacy shared root is kept until a per-target record covers it" {
  # Recreate a pre-upgrade install: target A's link, rooted only by the
  # legacy shared `claude-skill-alpha`.
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  local legacy="$GCROOTS_DIR/claude-skill-alpha" store_path
  store_path=$(gc_record_store_path alpha "$TARGET_A")
  rm -r "$GCROOTS_DIR/claude-skills"
  ln -s "$store_path" "$legacy"

  # Ownership still recognizes a broken link through the legacy root.
  ln -s /nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-gone/share/claude-skills/beta "$TARGET_A/beta"
  ln -s /nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-gone "$GCROOTS_DIR/claude-skill-beta"

  # Installing into another target, then uninstalling there, never touches
  # the legacy root: it may be target A's only protection.
  app_in "$INSTALL_ALL_APP" "$TARGET_B" alpha
  assert_success
  assert_equal "$(readlink "$legacy")" "$store_path"
  app_in "$UNINSTALL_ALL_APP" "$TARGET_B" alpha
  assert_success
  assert_equal "$(readlink "$legacy")" "$store_path"

  # Reap keeps it while no per-target record covers its store path, but
  # removes the broken legacy-rooted beta.
  app_in "$REAP_ALL_APP" "$TARGET_A"
  assert_success
  assert_equal "$(readlink "$legacy")" "$store_path"
  refute [ -L "$TARGET_A/beta" ]
  refute [ -L "$GCROOTS_DIR/claude-skill-beta" ]

  # Re-installing target A gives it its own record and leaves the legacy
  # root; the next reap removes the now-redundant legacy root.
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  assert [ -L "$legacy" ]
  app_in "$REAP_ALL_APP" "$TARGET_A"
  assert_success
  assert_output --partial "superseded by a per-target root"
  refute [ -L "$legacy" ]
  assert_gc_rooted alpha "$TARGET_A"
  assert [ -f "$TARGET_A/alpha/SKILL.md" ]
  assert_equal "$(jq -r '.skills.alpha.storePath' "$TARGET_A/.agent-skill-flake-lock.json")" "$store_path"
}

@test "install moves a target's flat roots into records, leaving other targets' flat roots" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha beta
  assert_success
  app_in "$INSTALL_ALL_APP" "$TARGET_B" alpha
  assert_success
  local alpha_sp beta_sp
  alpha_sp=$(gc_record_store_path alpha "$TARGET_A")
  beta_sp=$(gc_record_store_path beta "$TARGET_A")
  # Both targets as an older install left them: flat roots, alpha with a
  # previous build, and the flat records of their dirs.
  flatten_gc_roots "$TARGET_A"
  ln -s "$beta_sp" "$(flat_gc_root alpha.previous "$TARGET_A")"
  ln -s "$alpha_sp" "$(flat_gc_root alpha "$TARGET_B")"
  ln -s "$(realpath -m -- "$TARGET_B")" "$(flat_gc_root_record "$TARGET_B")"

  app_in "$RECONCILE_ALL_APP" "$TARGET_A"
  assert_success
  assert_gc_rooted alpha "$TARGET_A"
  assert_gc_rooted beta "$TARGET_A"
  assert_equal "$(gc_record_store_path alpha.previous "$TARGET_A")" "$beta_sp"
  assert_equal "$(readlink "$(gc_root_record "$TARGET_A")")" "$(realpath -m -- "$TARGET_A")"
  assert_equal "$(find "$GCROOTS_DIR" -maxdepth 1 -name "claude-skill-$(gc_root_tag "$TARGET_A")*" | wc -l)" 0

  # Target B's flat roots keep protecting its link until B migrates.
  assert_equal "$(readlink "$(flat_gc_root alpha "$TARGET_B")")" "$alpha_sp"
  run "$CHECK_ALL_APP" --scope=custom --root="$TARGET_B" --gcroots-dir="$GCROOTS_DIR"
  assert_success
  assert_output ''
}

@test "migration keeps a newer flat build as the previous one, losing no live root" {
  # An older agent-skill-flake, pinned by another flake, installs a
  # different build into a target the shared layout already records.
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha beta
  assert_success
  local alpha_sp beta_sp
  alpha_sp=$(gc_record_store_path alpha "$TARGET_A")
  beta_sp=$(gc_record_store_path beta "$TARGET_A")
  ln -s "$beta_sp" "$(flat_gc_root alpha "$TARGET_A")"

  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  assert_equal "$(gc_record_store_path alpha "$TARGET_A")" "$alpha_sp"
  assert_equal "$(gc_record_store_path alpha.previous "$TARGET_A")" "$beta_sp"
  refute [ -L "$(flat_gc_root alpha "$TARGET_A")" ]
}

@test "flat roots keep working until pruned" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  app_in "$INSTALL_ALL_APP" "$TARGET_B" alpha
  assert_success
  flatten_gc_roots "$TARGET_A"
  local flat_a
  flat_a=$(flat_gc_root alpha "$TARGET_A")
  # A broken entry whose only root is the target's flat root is still ours.
  ln -s /nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-gone/share/claude-skills/beta "$TARGET_A/beta"
  ln -s /nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-gone "$(flat_gc_root beta "$TARGET_A")"

  app_in "$REAP_ALL_APP" "$TARGET_B"
  assert_success
  assert_store_symlink "$flat_a" "target A's flat root"
  refute [ -L "$(flat_gc_root beta "$TARGET_A")" ]

  ln -s /nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-gone "$(flat_gc_root beta "$TARGET_A")"
  app_in "$REAP_ALL_APP" "$TARGET_A"
  assert_success
  refute [ -L "$TARGET_A/beta" ]
  assert_store_symlink "$flat_a" "target A's flat root"

  # A gone target's flat roots go by its flat record, as they always did.
  rm -r "$TARGET_A"
  app_in "$REAP_ALL_APP" "$TARGET_B"
  assert_success
  assert_output --partial "reaped GC root (install target gone): $flat_a"
  refute [ -L "$flat_a" ]
  refute [ -L "$(flat_gc_root_record "$TARGET_A")" ]
}

@test "migration writes the new record of the target dir first, keeping the flat one while a flat root stays" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha beta
  assert_success
  flatten_gc_roots "$TARGET_A"
  # A directory where alpha's record goes makes its move fail.
  mkdir -p "$(gc_record alpha "$TARGET_A")"

  app_in "$RECONCILE_ALL_APP" "$TARGET_A"
  assert_success
  assert_output --partial "could not move every flat GC root of $TARGET_A into records"
  assert_equal "$(readlink "$(gc_root_record "$TARGET_A")")" "$(realpath -m -- "$TARGET_A")"
  assert_store_symlink "$(flat_gc_root alpha "$TARGET_A")" "alpha's flat root"
  assert [ -L "$(flat_gc_root_record "$TARGET_A")" ]
  assert_gc_rooted beta "$TARGET_A"

  rmdir "$(gc_record alpha "$TARGET_A")"
  app_in "$RECONCILE_ALL_APP" "$TARGET_A"
  assert_success
  assert_gc_rooted alpha "$TARGET_A"
  refute [ -L "$(flat_gc_root alpha "$TARGET_A")" ]
  refute [ -L "$(flat_gc_root_record "$TARGET_A")" ]
}

@test "reap relinks its target's records that a copy split from their anchors" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  local rec
  rec=$(gc_record alpha "$TARGET_A")
  # As `cp -r` of the GC-roots dir leaves it: the same bytes, its own file.
  cp "$rec" "$rec.copy"
  mv -f "$rec.copy" "$rec"
  refute [ "$rec" -ef "$(gc_shared_root "$(cat "$rec")").refs" ]

  app_in "$REAP_ALL_APP" "$TARGET_A"
  assert_success
  refute_output --partial 'no record left'
  assert_gc_rooted alpha "$TARGET_A"
}

@test "an install relinks its target's previous-build records that a copy split from their anchors" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha beta
  assert_success
  local beta_sp rec
  beta_sp=$(gc_record_store_path beta "$TARGET_A")
  # alpha's previous build is a store path no current record uses.
  fake_gc_record alpha.previous "$beta_sp" "$TARGET_A"
  app_in "$UNINSTALL_ALL_APP" "$TARGET_A" beta
  assert_success
  rec=$(gc_record alpha.previous "$TARGET_A")
  cp "$rec" "$rec.copy"
  mv -f "$rec.copy" "$rec"
  assert_equal "$(anchor_links "$beta_sp")" 1

  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  assert [ "$rec" -ef "$(gc_shared_root "$beta_sp").refs" ]

  # A reap in another target, which relinks only its own records, keeps
  # the root.
  app_in "$REAP_ALL_APP" "$TARGET_B"
  assert_success
  refute_output --partial 'no record left'
  assert_equal "$(readlink "$(gc_shared_root "$beta_sp")")" "$beta_sp"
}

@test "a gone target's record doesn't cover a legacy root in a dry run or a run without the lock" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  local store_path legacy="$GCROOTS_DIR/claude-skill-alpha"
  store_path=$(gc_record_store_path alpha "$TARGET_A")
  ln -s "$store_path" "$legacy"
  rm -r "$TARGET_A"

  app_in "$PURGE_ALL_APP" "$TARGET_B" --dry-run
  assert_success
  refute_output --partial "legacy, superseded"
  assert_output --partial "would purge GC root (install target gone): $(gc_record alpha "$TARGET_A")"

  hold_gc_lock
  run env AGENT_SKILL_FLAKE_GC_LOCK_TIMEOUT=1 "$REAP_ALL_APP" \
    --scope=custom --root="$TARGET_B" --gcroots-dir="$GCROOTS_DIR"
  release_gc_lock
  assert_success
  assert_output --partial 'timed out waiting for '
  refute_output --partial "legacy, superseded"
  assert_equal "$(readlink "$legacy")" "$store_path"
}

@test "a purge's own entries don't cover a legacy root in a dry run or a run without the lock" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  local store_path legacy="$GCROOTS_DIR/claude-skill-alpha"
  store_path=$(gc_record_store_path alpha "$TARGET_A")
  ln -s "$store_path" "$legacy"

  app_in "$PURGE_ALL_APP" "$TARGET_A" --dry-run
  assert_success
  assert_output --partial "would purge: $TARGET_A/alpha"
  refute_output --partial "legacy, superseded"

  hold_gc_lock
  run env AGENT_SKILL_FLAKE_GC_LOCK_TIMEOUT=1 "$PURGE_ALL_APP" \
    --scope=custom --root="$TARGET_A" --gcroots-dir="$GCROOTS_DIR" --yes
  release_gc_lock
  assert_success
  assert_output --partial 'timed out waiting for '
  refute [ -e "$TARGET_A/alpha" ]
  refute_output --partial "legacy, superseded"
  assert_equal "$(readlink "$legacy")" "$store_path"
}

@test "a purge dry run's own flat roots don't cover a legacy root" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  local store_path legacy="$GCROOTS_DIR/claude-skill-alpha"
  store_path=$(gc_record_store_path alpha "$TARGET_A")
  flatten_gc_roots "$TARGET_A"
  ln -s "$store_path" "$legacy"

  app_in "$PURGE_ALL_APP" "$TARGET_A" --dry-run
  assert_success
  assert_output --partial "would purge: $TARGET_A/alpha"
  refute_output --partial "legacy, superseded"
  assert_equal "$(readlink "$legacy")" "$store_path"
}

@test "an uninstall without the lock removes the link and lock entry, keeping the records" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  local sp
  sp=$(gc_record_store_path alpha "$TARGET_A")

  hold_gc_lock
  run env AGENT_SKILL_FLAKE_GC_LOCK_TIMEOUT=1 "$UNINSTALL_ALL_APP" \
    --scope=custom --root="$TARGET_A" --gcroots-dir="$GCROOTS_DIR" alpha
  release_gc_lock
  assert_success
  assert_output --partial 'timed out waiting for '
  refute [ -L "$TARGET_A/alpha" ]
  assert_equal "$(jq -r '.skills.alpha // "gone"' "$TARGET_A/.agent-skill-flake-lock.json")" gone
  assert_gc_rooted alpha "$TARGET_A"
  assert_equal "$(readlink "$(gc_shared_root "$sp")")" "$sp"
}

@test "a new build links the previous-build record to the old anchor, not to a split record" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" beta
  assert_success
  local old_sp rec
  old_sp=$(gc_record_store_path beta "$TARGET_A")
  # alpha's record holds another build, then a copy splits it.
  fake_gc_record alpha "$old_sp" "$TARGET_A"
  rec=$(gc_record alpha "$TARGET_A")
  cp "$rec" "$rec.copy"
  mv -f "$rec.copy" "$rec"

  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  assert [ "$rec.previous" -ef "$(gc_shared_root "$old_sp").refs" ]
  assert_equal "$(anchor_links "$old_sp")" 3
}

@test "parallel installs, uninstalls and reaps, taking a root's count down to 1, never drop a root a record uses" {
  local i pid
  local -a pids=()
  # No target holds alpha for the whole run: each worker drops and adds
  # its record again and again, so the anchor's count falls to 1 while
  # other workers link to it.
  for i in 1 2 3 4 5 6; do
    (
      t="$BATS_TEST_TMPDIR/parallel-$i"
      a=(--scope=custom --root="$t" --gcroots-dir="$GCROOTS_DIR")
      for round in 1 2 3; do
        "$INSTALL_ALL_APP" "${a[@]}" alpha && "$UNINSTALL_ALL_APP" "${a[@]}" alpha || exit 1
      done
      "$INSTALL_ALL_APP" "${a[@]}" alpha
    ) >"$BATS_TEST_TMPDIR/parallel-$i.log" 2>&1 &
    pids+=("$!")
  done
  mkdir -p "$BATS_TEST_TMPDIR/reaper"
  for i in 1 2 3; do
    "$REAP_ALL_APP" --scope=custom --root="$BATS_TEST_TMPDIR/reaper" --gcroots-dir="$GCROOTS_DIR" \
      >"$BATS_TEST_TMPDIR/reap-$i.log" 2>&1 &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || fail "a parallel run failed: $(cat "$BATS_TEST_TMPDIR"/*.log)"
  done

  local alpha_sp
  alpha_sp=$(gc_record_store_path alpha "$BATS_TEST_TMPDIR/parallel-1")
  for i in 1 2 3 4 5 6; do
    assert_gc_rooted alpha "$BATS_TEST_TMPDIR/parallel-$i"
  done
  assert_equal "$(anchor_links "$alpha_sp")" 7
  assert_equal "$(find "$GCROOTS_DIR/claude-skills/tmp" -mindepth 1 | wc -l)" 0
}

@test "an uninstall waits for the lock before it removes a record" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  local rec pid
  rec=$(gc_record alpha "$TARGET_A")
  hold_gc_lock

  "$UNINSTALL_ALL_APP" --scope=custom --root="$TARGET_A" --gcroots-dir="$GCROOTS_DIR" alpha \
    >"$BATS_TEST_TMPDIR/uninstall.log" 2>&1 &
  pid=$!
  # The link goes before the lock is taken; the record only after.
  wait_for_line "$BATS_TEST_TMPDIR/uninstall.log" 'Waiting for '
  for _ in $(seq 600); do
    [ -L "$TARGET_A/alpha" ] || break
    sleep 0.1
  done
  refute [ -L "$TARGET_A/alpha" ]
  assert [ -f "$rec" ]

  release_gc_lock
  wait "$pid"
  refute [ -e "$rec" ]
}

@test "a root survives a record added while the remover waited for the lock" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  local sp pid
  sp=$(gc_record_store_path alpha "$TARGET_A")
  hold_gc_lock

  "$UNINSTALL_ALL_APP" --scope=custom --root="$TARGET_A" --gcroots-dir="$GCROOTS_DIR" alpha \
    >"$BATS_TEST_TMPDIR/uninstall.log" 2>&1 &
  pid=$!
  wait_for_line "$BATS_TEST_TMPDIR/uninstall.log" 'Waiting for '
  # Another run, holding the lock, links target B's record to the anchor
  # whose only other record the waiting uninstall is about to remove.
  fake_gc_record alpha "$sp" "$TARGET_B"
  release_gc_lock
  wait "$pid"

  refute [ -e "$(gc_record alpha "$TARGET_A")" ]
  assert_equal "$(readlink "$(gc_shared_root "$sp")")" "$sp"
  assert [ "$(gc_record alpha "$TARGET_B")" -ef "$(gc_shared_root "$sp").refs" ]
  assert_equal "$(anchor_links "$sp")" 2
}

@test "after one lock timeout, a run stops waiting and changes nothing more" {
  hold_gc_lock

  run env AGENT_SKILL_FLAKE_GC_LOCK_TIMEOUT=1 "$INSTALL_ALL_APP" \
    --scope=custom --root="$TARGET_A" --gcroots-dir="$GCROOTS_DIR" alpha beta
  release_gc_lock
  assert_success
  assert_equal "$(grep -c 'Waiting for ' <<<"$output")" 1
  assert_equal "$(grep -c 'timed out waiting for ' <<<"$output")" 1
  assert_output --partial 'could not write GC root for alpha'
  assert_output --partial 'could not write GC root for beta'
  assert [ -L "$TARGET_A/alpha" ]
  refute [ -e "$(gc_record alpha "$TARGET_A")" ]
  refute [ -e "$(gc_root_record "$TARGET_A")" ]
}
