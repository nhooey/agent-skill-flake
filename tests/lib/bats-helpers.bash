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

# The GC-root layout, spelled out here rather than reusing scope.bash, so
# the tests pin the on-disk names independently of the code that writes
# them. A target with tag <tag> (the first 12 hex of sha256(resolved
# dir)) records each skill <name> it installs as
#   $GCROOTS_DIR/claude-skills/targets/<tag>/<name>
# a hard link of its build's anchor, $GCROOTS_DIR/claude-skills/store/
# <store-path-name>.refs, beside the shared root, store/<store-path-name>,
# a link to the store path.

# gc_record <name> [<target-dir>]  ->  the record an install into
# <target-dir> (default: $CUSTOM_TARGET) makes for <name>.
gc_record() {
  local name=$1 dir=${2:-$CUSTOM_TARGET}
  printf '%s/claude-skills/targets/%s/%s' "$GCROOTS_DIR" "$(gc_root_tag "$dir")" "$name"
}

# gc_shared_root <store-path>  ->  the shared root for <store-path>.
gc_shared_root() {
  printf '%s/claude-skills/store/%s' "$GCROOTS_DIR" "${1##*/}"
}

# gc_record_store_path <name> [<target-dir>]  ->  the store path the
# record holds.
gc_record_store_path() {
  cat "$(gc_record "$@")"
}

# assert_gc_rooted <name> [<target-dir>]  —  the target's record for
# <name> holds a /nix/store path, is a hard link of that path's anchor,
# and the path's shared root links it.
assert_gc_rooted() {
  local rec sp root
  rec=$(gc_record "$@")
  assert [ -f "$rec" ]
  sp=$(cat "$rec")
  case "$sp" in
  /nix/store/*) ;;
  *) fail "expected a /nix/store path in $rec, got: $sp" ;;
  esac
  root=$(gc_shared_root "$sp")
  assert_equal "$(readlink "$root")" "$sp"
  assert [ "$rec" -ef "$root.refs" ]
}

# fake_gc_record <name> <store-path> [<target-dir>]  —  write the shared
# root, the anchor and the record an install of <store-path> as <name>
# would, for a store path no install can make, such as one that's gone.
fake_gc_record() {
  local name=$1 sp=$2 dir=${3:-$CUSTOM_TARGET} root rec
  root=$(gc_shared_root "$sp")
  rec=$(gc_record "$name" "$dir")
  mkdir -p "${root%/*}" "${rec%/*}"
  ln -sfn "$sp" "$root"
  [ -f "$root.refs" ] || printf '%s\n' "$sp" >"$root.refs"
  ln -f "$root.refs" "$rec"
}

# hold_gc_lock  —  take the GC-root layout's lock from the test, as another
# run would, until release_gc_lock. Needs flock(1) on PATH.
hold_gc_lock() {
  mkdir -p "$GCROOTS_DIR/claude-skills"
  exec {GC_LOCK_FD}>>"$GCROOTS_DIR/claude-skills/lock"
  flock -x "$GC_LOCK_FD"
}

release_gc_lock() {
  flock -u "$GC_LOCK_FD"
  exec {GC_LOCK_FD}>&-
}

# wait_for_line <file> <text>  —  wait, up to 60 s, until <file> holds a
# line containing <text>, such as a run's "Waiting for <lock>...".
wait_for_line() {
  local _
  for _ in $(seq 600); do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  fail "no line with '$2' in $1: $(cat "$1" 2>/dev/null)"
}

# gc_root_tag <target-dir>  ->  the first 12 hex of sha256(resolved dir).
gc_root_tag() {
  printf '%s' "$(realpath -m -- "$1")" | sha256sum | cut -c1-12
}

# gc_root_record [<target-dir>]  ->  the record an install into
# <target-dir> (default: $CUSTOM_TARGET) leaves of its own dir:
# $GCROOTS_DIR/claude-skills/targets/<tag>/.target, a link to the
# resolved dir.
gc_root_record() {
  local dir=${1:-$CUSTOM_TARGET}
  printf '%s/claude-skills/targets/%s/.target' "$GCROOTS_DIR" "$(gc_root_tag "$dir")"
}

# flat_gc_root <name> [<target-dir>]  ->  the flat per-target root an
# install from an agent-skill-flake rev before the shared layout made:
# $GCROOTS_DIR/claude-skill-<tag>-<name>.
flat_gc_root() {
  local name=$1 dir=${2:-$CUSTOM_TARGET}
  printf '%s/claude-skill-%s-%s' "$GCROOTS_DIR" "$(gc_root_tag "$dir")" "$name"
}

# flat_gc_root_record [<target-dir>]  ->  the flat record of the target's
# dir beside its flat roots: $GCROOTS_DIR/claude-skill-<tag>.target.
flat_gc_root_record() {
  local dir=${1:-$CUSTOM_TARGET}
  printf '%s/claude-skill-%s.target' "$GCROOTS_DIR" "$(gc_root_tag "$dir")"
}

# flatten_gc_roots [<target-dir>]  —  turn the target's records into the
# flat roots and flat record an older install would have left, as links
# straight to the store paths, and drop the shared roots no other
# target's record uses.
flatten_gc_roots() {
  local dir=${1:-$CUSTOM_TARGET} records rec anchor
  records=$GCROOTS_DIR/claude-skills/targets/$(gc_root_tag "$dir")
  for rec in "$records"/*; do
    ln -sfn "$(cat "$rec")" "$(flat_gc_root "${rec##*/}" "$dir")"
  done
  ln -sfn "$(realpath -m -- "$dir")" "$(flat_gc_root_record "$dir")"
  rm -r "$records"
  for anchor in "$GCROOTS_DIR"/claude-skills/store/*.refs; do
    if [ "$(stat -c %h "$anchor")" -eq 1 ]; then
      rm "$anchor" "${anchor%.refs}"
    fi
  done
}
