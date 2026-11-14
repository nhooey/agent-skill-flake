#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP, UNINSTALL_ALL_APP, REAP_ALL_APP — aggregate
#         entrypoints (alpha + beta).
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
