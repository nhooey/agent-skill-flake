# Shared helpers for tests/checks/*.bats. Each test sources this file via
# the $BATS_HELPERS env var injected by mkBatsCheck in checks.nix. Sourcing
# it also loads the bats-support / bats-assert / bats-file libraries.

bats_load_library bats-support
bats_load_library bats-assert
bats_load_library bats-file

# Isolated HOME + skills target + GC root dir under the per-test tmpdir.
# Most install/uninstall/reap/reconcile tests need exactly this triplet;
# preview tests need only HOME + CLAUDE_SKILLS_DIR but the extra dirs are
# harmless.
setup_isolated_env() {
  export HOME="$BATS_TEST_TMPDIR/fake-home"
  export CLAUDE_SKILLS_DIR="$BATS_TEST_TMPDIR/skills-target"
  export NIX_GCROOTS_DIR="$BATS_TEST_TMPDIR/gcroots"
  mkdir -p "$HOME/.claude/skills" "$NIX_GCROOTS_DIR"
}

# assert_store_symlink <path> [label]
# Asserts <path> is a symlink whose target lives in /nix/store.
assert_store_symlink() {
  local path=$1 label=${2:-$1} target
  assert [ -L "$path" ]
  target=$(readlink "$path")
  case "$target" in
    /nix/store/*) ;;
    *) fail "expected /nix/store target for $label, got: $target" ;;
  esac
}

# snapshot_fs <paths...>  ->  sorted listing on stdout
# Missing paths are skipped, so callers can pass paths that may not exist.
snapshot_fs() {
  find "$@" 2>/dev/null | sort || true
}
