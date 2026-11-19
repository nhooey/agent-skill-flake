#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP — aggregate install (alpha + beta);
#         PRUNE_GC_ROOTS_APP — the one-time GC-root sweep.
#
# prune-gc-roots drops the per-target records and flat roots no install
# target it can find still owns: those of a target dir that is gone, such
# as a removed git worktree's `.agents/skills`, which still point at live
# store paths and so outlive every reap. It finds targets by their lock
# files, by the records of their dirs installs leave beside their roots,
# and by the personal scope dir. A shared root goes when its last record
# goes.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  TARGET_KEEP="$HOME/work/keep/.agents/skills"
  TARGET_GONE="$HOME/work/gone/.agents/skills"
  TARGET_OUTSIDE="$BATS_TEST_TMPDIR/outside/.agents/skills"
}

install_into() {
  local target=$1
  shift
  run "$INSTALL_ALL_APP" --scope=custom --root="$target" --gcroots-dir="$GCROOTS_DIR" "$@"
  assert_success
}

# Make every entry older than prune's one-hour grace: the flat links, and
# each target's records dir, whose time is its records' age.
age_roots() {
  touch -h -d '2 hours ago' "$GCROOTS_DIR"/* "$GCROOTS_DIR"/claude-skills/targets/*
}

# Drop the records of target dirs installs leave, as for roots written
# before them.
drop_records() {
  rm -f "$GCROOTS_DIR"/claude-skills/targets/*/.target "$GCROOTS_DIR"/claude-skill-*.target
}

prune() {
  run "$PRUNE_GC_ROOTS_APP" --gcroots-dir="$GCROOTS_DIR" "$@"
}

@test "the dry run is the default: it lists what it would remove, with counts" {
  install_into "$TARGET_KEEP" alpha beta
  install_into "$TARGET_GONE" alpha beta
  drop_records
  rm -r "$TARGET_GONE"
  age_roots
  local before
  before=$(snapshot_fs "$GCROOTS_DIR")

  prune
  assert_success
  assert_output --partial "would remove (install target not found): $(gc_record alpha "$TARGET_GONE")"
  assert_output --partial "would remove (install target not found): $(gc_record beta "$TARGET_GONE")"
  refute_output --partial "$(gc_record alpha "$TARGET_KEEP")"
  refute_output --partial "no record left"
  assert_output --partial "Would remove 2 of 4 records and claude-skill-* entries"
  assert_output --partial "2 records of 1 install target not found"
  assert_output --partial "and 0 shared roots no record uses any more."
  assert_output --partial "Kept 2: 2 records of found install targets"
  assert_output --partial "--delete"
  assert_equal "$(snapshot_fs "$GCROOTS_DIR")" "$before"
}

@test "--delete removes only what no found target owns, and the roots left without a record" {
  install_into "$TARGET_KEEP" alpha beta
  install_into "$TARGET_GONE" alpha beta
  drop_records
  rm -r "$TARGET_GONE"
  local alpha_sp beta_sp
  alpha_sp=$(gc_record_store_path alpha "$TARGET_KEEP")
  beta_sp=$(gc_record_store_path beta "$TARGET_KEEP")
  # A found target that no longer links beta doesn't own beta's record.
  rm "$TARGET_KEEP/beta"
  # Entries prune must leave: a legacy shared root, another tool's root
  # and a file that isn't a link.
  ln -s "$alpha_sp" "$GCROOTS_DIR/claude-skill-alpha"
  ln -s "$alpha_sp" "$GCROOTS_DIR/other-tool-root"
  touch "$GCROOTS_DIR/claude-skill-0123456789ab-not-a-link"
  age_roots

  prune --delete
  assert_success
  assert_output --partial "removed (install target not found): $(gc_record alpha "$TARGET_GONE")"
  assert_output --partial "removed (install target not found): $(gc_record beta "$TARGET_GONE")"
  assert_output --partial "removed (skill no longer linked): $(gc_record beta "$TARGET_KEEP")"
  assert_output --partial "removed (no record left): $(gc_shared_root "$beta_sp")"
  assert_output --partial "Removed 3 of 5"
  assert_output --partial "and 1 shared root no record uses any more."
  refute [ -e "$(gc_record alpha "$TARGET_GONE")" ]
  refute [ -e "$(gc_record beta "$TARGET_KEEP")" ]
  refute [ -L "$(gc_shared_root "$beta_sp")" ]
  refute [ -e "$(gc_shared_root "$beta_sp").refs" ]
  assert_gc_rooted alpha "$TARGET_KEEP"
  assert [ -L "$GCROOTS_DIR/claude-skill-alpha" ]
  assert [ -L "$GCROOTS_DIR/other-tool-root" ]
  assert [ -f "$GCROOTS_DIR/claude-skill-0123456789ab-not-a-link" ]
  assert [ -d "$alpha_sp" ]
}

@test "a shared root goes only with its last record, and the dry run says which" {
  install_into "$TARGET_KEEP" alpha
  install_into "$TARGET_GONE" alpha beta
  drop_records
  rm -r "$TARGET_GONE"
  local alpha_sp beta_sp
  alpha_sp=$(gc_record_store_path alpha "$TARGET_KEEP")
  beta_sp=$(gc_record_store_path beta "$TARGET_GONE")
  age_roots

  prune
  assert_success
  assert_output --partial "would remove (no record left): $(gc_shared_root "$beta_sp")"
  refute_output --partial "would remove (no record left): $(gc_shared_root "$alpha_sp")"

  prune --delete
  assert_success
  refute [ -L "$(gc_shared_root "$beta_sp")" ]
  assert_gc_rooted alpha "$TARGET_KEEP"
  refute [ -d "${GCROOTS_DIR}/claude-skills/targets/$(gc_root_tag "$TARGET_GONE")" ]
}

@test "a previous-build record stays only beside a live target's current record" {
  install_into "$TARGET_KEEP" alpha beta
  install_into "$TARGET_GONE" alpha
  drop_records
  rm -r "$TARGET_GONE"
  local sp
  sp=$(gc_record_store_path beta "$TARGET_KEEP")
  fake_gc_record alpha.previous "$sp" "$TARGET_KEEP"
  fake_gc_record beta.previous "$sp" "$TARGET_KEEP"
  fake_gc_record alpha.previous "$sp" "$TARGET_GONE"
  rm "$(gc_record beta "$TARGET_KEEP")"
  age_roots

  prune --delete
  assert_success
  assert_output --partial "removed (previous build, current root gone): $(gc_record beta.previous "$TARGET_KEEP")"
  assert_output --partial "removed (install target not found): $(gc_record alpha.previous "$TARGET_GONE")"
  assert_output --partial "1 previous-build record whose current record is gone"
  assert [ -f "$(gc_record alpha.previous "$TARGET_KEEP")" ]
  refute [ -e "$(gc_record beta.previous "$TARGET_KEEP")" ]
  refute [ -e "$(gc_record alpha.previous "$TARGET_GONE")" ]
  assert_equal "$(readlink "$(gc_shared_root "$sp")")" "$sp"
}

@test "records younger than an hour are kept" {
  install_into "$TARGET_KEEP" alpha
  install_into "$TARGET_GONE" alpha
  drop_records
  rm -r "$TARGET_GONE"

  prune --delete
  assert_success
  assert_output --partial "1 younger than an hour"
  assert_gc_rooted alpha "$TARGET_GONE"
}

@test "flat roots no found target owns are pruned as before" {
  install_into "$TARGET_GONE" alpha
  flatten_gc_roots "$TARGET_GONE"
  drop_records
  rm -r "$TARGET_GONE"
  install_into "$TARGET_KEEP" alpha
  age_roots

  prune --delete
  assert_success
  assert_output --partial "removed (install target not found): $(flat_gc_root alpha "$TARGET_GONE")"
  refute [ -L "$(flat_gc_root alpha "$TARGET_GONE")" ]
  assert_gc_rooted alpha "$TARGET_KEEP"
}

@test "--search finds install targets outside HOME" {
  install_into "$TARGET_OUTSIDE" alpha
  drop_records
  age_roots

  prune
  assert_success
  assert_output --partial "would remove (install target not found): $(gc_record alpha "$TARGET_OUTSIDE")"

  # --search adds to $HOME rather than replacing it.
  install_into "$TARGET_KEEP" alpha
  drop_records
  age_roots
  prune --delete --search="$BATS_TEST_TMPDIR/outside"
  assert_success
  assert_output --partial "Removed 0 of 2"
  assert_gc_rooted alpha "$TARGET_OUTSIDE"
  assert_gc_rooted alpha "$TARGET_KEEP"
}

@test "the personal scope dir is a target even through a link out of HOME" {
  local real="$BATS_TEST_TMPDIR/personal-skills"
  mkdir -p "$HOME/.claude"
  ln -s "$real" "$HOME/.claude/skills"
  install_into "$real" alpha
  install_into "$TARGET_KEEP" alpha
  drop_records
  age_roots

  prune --delete
  assert_success
  assert_gc_rooted alpha "$real"
}

@test "a search dir that doesn't exist is a usage error" {
  prune --search="$BATS_TEST_TMPDIR/no-such-dir"
  assert_failure 2
  assert_output --partial "no dir to search at $BATS_TEST_TMPDIR/no-such-dir"
}

@test "--delete is refused when the search finds no lock file" {
  install_into "$TARGET_OUTSIDE" alpha
  drop_records
  age_roots

  prune --delete
  assert_failure 1
  assert_output --partial "found no lock file"
  assert_gc_rooted alpha "$TARGET_OUTSIDE"
}

@test "the summary names each dir the search couldn't read" {
  install_into "$TARGET_KEEP" alpha
  mkdir -p "$HOME/locked"
  chmod u= "$HOME/locked"

  prune
  chmod u=rwx "$HOME/locked"
  assert_success
  assert_output --partial "The search could not read 1 path"
  assert_output --partial "$HOME/locked"
}

@test "a record of a target dir keeps its live target's records and goes with its gone target" {
  install_into "$TARGET_KEEP" alpha
  install_into "$TARGET_OUTSIDE" alpha
  install_into "$TARGET_GONE" alpha
  rm -r "$TARGET_GONE"
  age_roots

  prune --delete
  assert_success
  assert_output --partial "removed (install target gone): $(gc_root_record "$TARGET_GONE")"
  refute [ -L "$(gc_root_record "$TARGET_GONE")" ]
  refute [ -e "$(gc_record alpha "$TARGET_GONE")" ]
  assert [ -L "$(gc_root_record "$TARGET_OUTSIDE")" ]
  assert_gc_rooted alpha "$TARGET_OUTSIDE"
}

@test "--delete keeps a record whose target came back while it waited for the lock" {
  install_into "$TARGET_GONE" alpha
  local sp link
  sp=$(gc_record_store_path alpha "$TARGET_GONE")
  link=$(readlink "$TARGET_GONE/alpha")
  install_into "$TARGET_KEEP" alpha
  rm -r "$TARGET_GONE"
  age_roots
  hold_gc_lock

  "$PRUNE_GC_ROOTS_APP" --gcroots-dir="$GCROOTS_DIR" --delete >"$BATS_TEST_TMPDIR/prune.log" 2>&1 &
  local pid=$!
  wait_for_line "$BATS_TEST_TMPDIR/prune.log" 'Waiting for '
  # The worktree is made again at the same path, as an install leaves it.
  mkdir -p "$TARGET_GONE"
  ln -s "$link" "$TARGET_GONE/alpha"
  release_gc_lock
  wait "$pid"

  run cat "$BATS_TEST_TMPDIR/prune.log"
  refute_output --partial "removed (install target gone): $(gc_root_record "$TARGET_GONE")"
  assert_output --partial "2 changed since the search"
  assert_gc_rooted alpha "$TARGET_GONE"
  assert [ -L "$(gc_root_record "$TARGET_GONE")" ]
  assert_equal "$(readlink "$(gc_shared_root "$sp")")" "$sp"
}

@test "--delete racing an install into a remade target leaves the target rooted" {
  install_into "$TARGET_GONE" alpha
  install_into "$TARGET_KEEP" alpha
  rm -r "$TARGET_GONE"
  age_roots
  hold_gc_lock

  "$PRUNE_GC_ROOTS_APP" --gcroots-dir="$GCROOTS_DIR" --delete >"$BATS_TEST_TMPDIR/prune.log" 2>&1 &
  local prune_pid=$!
  wait_for_line "$BATS_TEST_TMPDIR/prune.log" 'Waiting for '
  "$INSTALL_ALL_APP" --scope=custom --root="$TARGET_GONE" --gcroots-dir="$GCROOTS_DIR" alpha \
    >"$BATS_TEST_TMPDIR/install.log" 2>&1 &
  local install_pid=$!
  wait_for_line "$BATS_TEST_TMPDIR/install.log" 'Waiting for '
  release_gc_lock
  wait "$prune_pid"
  wait "$install_pid"

  assert_gc_rooted alpha "$TARGET_GONE"
  assert_gc_rooted alpha "$TARGET_KEEP"
  assert [ -L "$(gc_root_record "$TARGET_GONE")" ]
}

@test "--delete without the lock leaves every record and counts no shared root" {
  install_into "$TARGET_KEEP" alpha
  install_into "$TARGET_GONE" beta
  drop_records
  rm -r "$TARGET_GONE"
  age_roots
  hold_gc_lock

  AGENT_SKILL_FLAKE_GC_LOCK_TIMEOUT=1 prune --delete
  release_gc_lock
  assert_success
  assert_output --partial "could not lock"
  assert_output --partial "Removed 0 of"
  assert_output --partial "and 0 shared roots no record uses any more."
  assert_output --partial "1 left unlocked"
  assert_gc_rooted beta "$TARGET_GONE"
}

@test "an unknown argument is a usage error" {
  prune --bogus
  assert_failure 2
  assert_output --partial "unexpected argument: --bogus"
}
