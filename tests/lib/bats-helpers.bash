# Shared helpers for tests/checks/*.bats. Each test sources this file via
# the $BATS_HELPERS env var injected by mkBatsCheck in checks.nix. Sourcing
# it also loads the bats-support / bats-assert / bats-file libraries.

bats_load_library bats-support
bats_load_library bats-assert
bats_load_library bats-file

# Isolated HOME + a `--scope=custom` install target + GC-roots dir under
# the per-test tmpdir. Most install/uninstall/reap/reconcile tests need
# exactly this triplet plus the scope_args[] array passed to every app
# invocation as --scope=custom --root=... --gcroots-dir=...
setup_isolated_env() {
  export HOME="$BATS_TEST_TMPDIR/fake-home"
  export CUSTOM_TARGET="$BATS_TEST_TMPDIR/skills-target"
  export GCROOTS_DIR="$BATS_TEST_TMPDIR/gcroots"
  mkdir -p "$HOME" "$GCROOTS_DIR"

  scope_args=(
    "--scope=custom"
    "--root=$CUSTOM_TARGET"
    "--gcroots-dir=$GCROOTS_DIR"
  )
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

# gc_root <name> [<target-dir>]  ->  the per-target GC root an install into
# <target-dir> (default: $CUSTOM_TARGET) makes for <name>:
# $GCROOTS_DIR/claude-skill-<first 12 hex of sha256(resolved dir)>-<name>.
# Spelled out here rather than reusing scope.bash, so the tests pin the
# on-disk name independently of the code that writes it.
gc_root() {
  local name=$1 dir=${2:-$CUSTOM_TARGET} tag
  tag=$(printf '%s' "$(realpath -m -- "$dir")" | sha256sum | cut -c1-12)
  printf '%s/claude-skill-%s-%s' "$GCROOTS_DIR" "$tag" "$name"
}
