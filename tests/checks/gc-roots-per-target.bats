#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP, UNINSTALL_ALL_APP, REAP_ALL_APP, PURGE_ALL_APP,
#         RECONCILE_ALL_APP — aggregate entrypoints (alpha + beta).
#
# Every install target keeps its own per-user GC root per skill. With one
# root name shared by every target, the last target to install a skill took
# the root and every other target's link pointed at an unrooted store path.
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

@test "two targets installing the same skill each keep their own root" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  app_in "$INSTALL_ALL_APP" "$TARGET_B" alpha
  assert_success

  local root_a root_b
  root_a=$(gc_root alpha "$TARGET_A")
  root_b=$(gc_root alpha "$TARGET_B")
  assert_not_equal "$root_a" "$root_b"
  assert_store_symlink "$root_a" "target A's root"
  assert_store_symlink "$root_b" "target B's root"
  assert_equal "$(readlink "$root_a")" "$(readlink "$root_b")"
  refute [ -e "$GCROOTS_DIR/claude-skill-alpha" ]
}

@test "uninstalling from one target leaves the other target's root" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  app_in "$INSTALL_ALL_APP" "$TARGET_B" alpha
  assert_success

  app_in "$UNINSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success

  refute [ -e "$TARGET_A/alpha" ]
  refute [ -e "$(gc_root alpha "$TARGET_A")" ]
  assert [ -f "$TARGET_B/alpha/SKILL.md" ]
  assert_store_symlink "$(gc_root alpha "$TARGET_B")" "target B's root"
}

@test "install and reconcile record the target dir beside its roots" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  assert_equal "$(readlink "$(gc_root_record "$TARGET_A")")" "$(realpath -m -- "$TARGET_A")"

  app_in "$RECONCILE_ALL_APP" "$TARGET_B"
  assert_success
  assert_equal "$(readlink "$(gc_root_record "$TARGET_B")")" "$(realpath -m -- "$TARGET_B")"
}

@test "reap drops the roots of an install target that no longer exists" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha beta
  assert_success
  app_in "$INSTALL_ALL_APP" "$TARGET_B" alpha
  assert_success
  local root_b store_path
  root_b=$(gc_root alpha "$TARGET_B")
  store_path=$(readlink "$root_b")

  # A worktree removed with its skills dir leaves roots that still point
  # at live store paths.
  rm -r "$TARGET_A"

  app_in "$REAP_ALL_APP" "$TARGET_B"
  assert_success
  assert_output --partial "reaped GC root (install target gone): $(gc_root alpha "$TARGET_A")"
  refute [ -L "$(gc_root alpha "$TARGET_A")" ]
  refute [ -L "$(gc_root beta "$TARGET_A")" ]
  refute [ -L "$(gc_root_record "$TARGET_A")" ]
  assert_equal "$(readlink "$root_b")" "$store_path"
  assert [ -L "$(gc_root_record "$TARGET_B")" ]
  assert [ -d "$store_path" ]
}

@test "reap keeps the roots of a target that has no record" {
  # Roots written before installs recorded their target: the tag alone
  # can't say whether the dir is gone, so reap leaves them.
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  rm "$(gc_root_record "$TARGET_A")"
  rm -r "$TARGET_A"

  app_in "$REAP_ALL_APP" "$TARGET_B"
  assert_success
  assert_store_symlink "$(gc_root alpha "$TARGET_A")" "target A's root"
}

@test "a target keeps the roots of its current and previous builds only" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha beta
  assert_success
  local root prev alpha_sp beta_sp older="$BATS_TEST_TMPDIR/older-build" gc
  root=$(gc_root alpha "$TARGET_A")
  prev=$root.previous
  alpha_sp=$(readlink "$root")
  beta_sp=$(readlink "$(gc_root beta "$TARGET_A")")
  # Stand-ins for alpha's last build (beta's store path) and the one
  # before it (a dir that exists, as a store path would).
  mkdir -p "$older"
  ln -sfn "$older" "$prev"
  ln -sfn "$beta_sp" "$root"

  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  assert_equal "$(readlink "$root")" "$alpha_sp"
  assert_equal "$(readlink "$prev")" "$beta_sp"
  for gc in "$GCROOTS_DIR"/*; do
    [ "$(readlink "$gc")" != "$older" ] || fail "$gc still roots the build before last"
  done

  # Reinstalling the same build moves nothing.
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  assert_equal "$(readlink "$prev")" "$beta_sp"
}

@test "reap drops a previous-build root whose current root is gone" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha beta
  assert_success
  local alpha_root beta_root beta_sp
  alpha_root=$(gc_root alpha "$TARGET_A")
  beta_root=$(gc_root beta "$TARGET_A")
  beta_sp=$(readlink "$beta_root")
  ln -s "$beta_sp" "$alpha_root.previous"
  ln -s "$(readlink "$alpha_root")" "$beta_root.previous"
  rm "$beta_root"

  app_in "$REAP_ALL_APP" "$TARGET_A"
  assert_success
  assert_output --partial "reaped GC root (previous build, current root gone): $beta_root.previous"
  refute [ -L "$beta_root.previous" ]
  assert_store_symlink "$alpha_root.previous" "alpha's previous-build root"
  assert_equal "$(jq -r '.skills.beta.storePath' "$TARGET_A/.agent-skill-flake-lock.json")" "$beta_sp"
}

@test "uninstall removes the previous-build root with the current one" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha beta
  assert_success
  local root
  root=$(gc_root alpha "$TARGET_A")
  ln -s "$(readlink "$(gc_root beta "$TARGET_A")")" "$root.previous"

  app_in "$UNINSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  refute [ -L "$root" ]
  refute [ -L "$root.previous" ]
}

@test "reconcile moves the build it replaces to the previous-build root" {
  app_in "$RECONCILE_ALL_APP" "$TARGET_A"
  assert_success
  local root alpha_sp beta_sp
  root=$(gc_root alpha "$TARGET_A")
  alpha_sp=$(readlink "$root")
  beta_sp=$(readlink "$(gc_root beta "$TARGET_A")")
  ln -sfn "$beta_sp" "$root"

  app_in "$RECONCILE_ALL_APP" "$TARGET_A"
  assert_success
  assert_equal "$(readlink "$root")" "$alpha_sp"
  assert_equal "$(readlink "$root.previous")" "$beta_sp"
}

@test "reaping a previous-build root whose build is gone leaves the lock alone" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  local root lock="$TARGET_A/.agent-skill-flake-lock.json" before
  root=$(gc_root alpha "$TARGET_A")
  ln -s /nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-gone "$root.previous"
  before=$(jq -c '.skills.alpha' "$lock")

  app_in "$REAP_ALL_APP" "$TARGET_A"
  assert_success
  assert_output --partial "reaped GC root (target gone): $root.previous"
  refute [ -L "$root.previous" ]
  assert_store_symlink "$root" "alpha's current root"
  assert_equal "$(jq -c '.skills.alpha' "$lock")" "$before"
}

@test "a previous-build root doesn't supersede a legacy root" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha beta
  assert_success
  local legacy="$GCROOTS_DIR/claude-skill-alpha" beta_sp
  beta_sp=$(readlink "$(gc_root beta "$TARGET_A")")
  # The legacy root's store path is only some target's previous build,
  # which its next rebuild moves on from.
  ln -s "$beta_sp" "$(gc_root alpha "$TARGET_A").previous"
  rm "$(gc_root beta "$TARGET_A")"
  ln -s "$beta_sp" "$legacy"

  app_in "$REAP_ALL_APP" "$TARGET_A"
  assert_success
  assert_equal "$(readlink "$legacy")" "$beta_sp"
}

@test "purge drops a gone target's roots, and its dry run only lists them" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  app_in "$INSTALL_ALL_APP" "$TARGET_B" alpha
  assert_success
  rm -r "$TARGET_A"

  app_in "$PURGE_ALL_APP" "$TARGET_B" --dry-run
  assert_success
  assert_output --partial "would purge GC root (install target gone): $(gc_root alpha "$TARGET_A")"
  assert [ -L "$(gc_root alpha "$TARGET_A")" ]

  app_in "$PURGE_ALL_APP" "$TARGET_B" --yes
  assert_success
  refute [ -L "$(gc_root alpha "$TARGET_A")" ]
  refute [ -L "$(gc_root_record "$TARGET_A")" ]
}

@test "a legacy root covered only by a gone target's root is kept" {
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  local store_path legacy="$GCROOTS_DIR/claude-skill-alpha"
  store_path=$(readlink "$(gc_root alpha "$TARGET_A")")
  ln -s "$store_path" "$legacy"
  rm -r "$TARGET_A"

  app_in "$REAP_ALL_APP" "$TARGET_B"
  assert_success
  refute [ -L "$(gc_root alpha "$TARGET_A")" ]
  assert_equal "$(readlink "$legacy")" "$store_path"
}

@test "a target reached through a symlink shares the resolved dir's root" {
  mkdir -p "$TARGET_A"
  ln -s "$TARGET_A" "$BATS_TEST_TMPDIR/target-a-link"

  app_in "$INSTALL_ALL_APP" "$BATS_TEST_TMPDIR/target-a-link" alpha
  assert_success
  assert_store_symlink "$(gc_root alpha "$TARGET_A")" "resolved target's root"

  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  refute_output --partial 'GC root: '
}

@test "a legacy shared root is kept until a per-target root covers it" {
  # Recreate a pre-upgrade install: target A's link, rooted only by the
  # legacy shared `claude-skill-alpha`.
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  local root_a legacy="$GCROOTS_DIR/claude-skill-alpha" store_path
  root_a=$(gc_root alpha "$TARGET_A")
  store_path=$(readlink "$root_a")
  rm "$root_a"
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

  # Reap keeps it while no per-target root covers its store path, but
  # removes the broken legacy-rooted beta.
  app_in "$REAP_ALL_APP" "$TARGET_A"
  assert_success
  assert_equal "$(readlink "$legacy")" "$store_path"
  refute [ -L "$TARGET_A/beta" ]
  refute [ -L "$GCROOTS_DIR/claude-skill-beta" ]

  # Re-installing target A gives it its own root and leaves the legacy one;
  # the next reap removes the now-redundant legacy root.
  app_in "$INSTALL_ALL_APP" "$TARGET_A" alpha
  assert_success
  assert [ -L "$legacy" ]
  app_in "$REAP_ALL_APP" "$TARGET_A"
  assert_success
  assert_output --partial "superseded by a per-target root"
  refute [ -L "$legacy" ]
  assert_equal "$(readlink "$root_a")" "$store_path"
  assert [ -f "$TARGET_A/alpha/SKILL.md" ]
  assert_equal "$(jq -r '.skills.alpha.storePath' "$TARGET_A/.agent-skill-flake-lock.json")" "$store_path"
}
