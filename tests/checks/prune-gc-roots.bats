#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP — aggregate install (alpha + beta);
#         PRUNE_GC_ROOTS_APP — the one-time GC-root sweep.
#
# prune-gc-roots drops the per-target roots no install target it can find
# still owns: the roots of a target dir that is gone, such as a removed git
# worktree's `.agents/skills`, which still point at live store paths and so
# outlive every reap. It finds targets by their lock files, by the records
# installs leave beside their roots, and by the personal scope dir.
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

# Make every entry in the gcroots dir older than prune's one-hour grace.
age_roots() {
  touch -h -d '2 hours ago' "$GCROOTS_DIR"/*
}

# Drop the records installs leave, as for roots written before them.
drop_records() {
  rm -f "$GCROOTS_DIR"/claude-skill-*.target
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
  assert_output --partial "would remove (install target not found): $(gc_root alpha "$TARGET_GONE")"
  assert_output --partial "would remove (install target not found): $(gc_root beta "$TARGET_GONE")"
  refute_output --partial "$(gc_root alpha "$TARGET_KEEP")"
  assert_output --partial "Would remove 2 of 4 claude-skill-* entries"
  assert_output --partial "2 roots of 1 install target not found"
  assert_output --partial "Kept 2: 2 roots of found install targets"
  assert_output --partial "--delete"
  assert_equal "$(snapshot_fs "$GCROOTS_DIR")" "$before"
}

@test "--delete removes only the claude-skill-* links no found target owns" {
  install_into "$TARGET_KEEP" alpha beta
  install_into "$TARGET_GONE" alpha beta
  drop_records
  rm -r "$TARGET_GONE"
  local store_path
  store_path=$(readlink "$(gc_root alpha "$TARGET_KEEP")")
  # A found target that no longer links beta doesn't own beta's root.
  rm "$TARGET_KEEP/beta"
  # Entries prune must leave: a legacy shared root, another tool's root
  # and a file that isn't a link.
  ln -s "$store_path" "$GCROOTS_DIR/claude-skill-alpha"
  ln -s "$store_path" "$GCROOTS_DIR/other-tool-root"
  touch "$GCROOTS_DIR/claude-skill-0123456789ab-not-a-link"
  age_roots

  prune --delete
  assert_success
  assert_output --partial "removed (install target not found): $(gc_root alpha "$TARGET_GONE")"
  assert_output --partial "removed (skill no longer linked): $(gc_root beta "$TARGET_KEEP")"
  assert_output --partial "Removed 3 of"
  refute [ -L "$(gc_root alpha "$TARGET_GONE")" ]
  refute [ -L "$(gc_root beta "$TARGET_GONE")" ]
  refute [ -L "$(gc_root beta "$TARGET_KEEP")" ]
  assert_equal "$(readlink "$(gc_root alpha "$TARGET_KEEP")")" "$store_path"
  assert [ -L "$GCROOTS_DIR/claude-skill-alpha" ]
  assert [ -L "$GCROOTS_DIR/other-tool-root" ]
  assert [ -f "$GCROOTS_DIR/claude-skill-0123456789ab-not-a-link" ]
  assert [ -d "$store_path" ]
}

@test "roots younger than an hour are kept" {
  install_into "$TARGET_KEEP" alpha
  install_into "$TARGET_GONE" alpha
  drop_records
  rm -r "$TARGET_GONE"

  prune --delete
  assert_success
  assert_output --partial "1 younger than an hour"
  assert_store_symlink "$(gc_root alpha "$TARGET_GONE")" "the new root"
}

@test "--search finds install targets outside HOME" {
  install_into "$TARGET_OUTSIDE" alpha
  drop_records
  age_roots

  prune
  assert_success
  assert_output --partial "would remove (install target not found): $(gc_root alpha "$TARGET_OUTSIDE")"

  # --search adds to $HOME rather than replacing it.
  install_into "$TARGET_KEEP" alpha
  drop_records
  age_roots
  prune --delete --search="$BATS_TEST_TMPDIR/outside"
  assert_success
  assert_output --partial "Removed 0 of 2"
  assert_store_symlink "$(gc_root alpha "$TARGET_OUTSIDE")" "the outside target's root"
  assert_store_symlink "$(gc_root alpha "$TARGET_KEEP")" "the target under HOME's root"
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
  assert_store_symlink "$(gc_root alpha "$real")" "the personal scope's root"
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
  assert_store_symlink "$(gc_root alpha "$TARGET_OUTSIDE")" "the unfound target's root"
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

@test "a record keeps its live target's roots and goes with its gone target" {
  install_into "$TARGET_KEEP" alpha
  install_into "$TARGET_OUTSIDE" alpha
  install_into "$TARGET_GONE" alpha
  rm -r "$TARGET_GONE"
  age_roots

  prune --delete
  assert_success
  assert_output --partial "removed (install target gone): $(gc_root_record "$TARGET_GONE")"
  refute [ -L "$(gc_root_record "$TARGET_GONE")" ]
  refute [ -L "$(gc_root alpha "$TARGET_GONE")" ]
  assert [ -L "$(gc_root_record "$TARGET_OUTSIDE")" ]
  assert_store_symlink "$(gc_root alpha "$TARGET_OUTSIDE")" "the recorded target's root"
}

@test "an unknown argument is a usage error" {
  prune --bogus
  assert_failure 2
  assert_output --partial "unexpected argument: --bogus"
}
