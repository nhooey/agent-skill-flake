# root-check-dependencies: keep a repository's check dependencies from
# garbage collection. Prepended by lib/root-check-dependencies.nix with
#   ROOT_CHECK_DEPENDENCIES_SYSTEM  the system whose checks are rooted
#   ROOT_CHECK_DEPENDENCIES_EXPR    lib/check-dependencies.nix in the store

print_help() {
  cat <<EOF
Usage: root-check-dependencies [--flake=<dir>] [--system=<system>] [--force] [--background]

Roots the dependencies of the flake's checks.<system> under one indirect
GC root per repository, so garbage collection keeps them while the
repository uses them and frees them once a refresh supersedes them.

It evaluates the checks, builds nothing, and roots one store file that
refers to every check's derivation. With keep-outputs = true in nix.conf,
that keeps every input derivation's output already in the store, such as
crane's cargoArtifacts; without it, only the derivations are kept.

The root is <git-common-dir>/agent-skill-flake/check-dependencies, inside
the repository's .git directory, so git never tracks it and every worktree
of the repository shares it. A refresh runs only when a tracked or
untracked, not ignored, *.nix, *.lock, go.sum, Package.resolved,
package-lock.json or pnpm-lock.yaml file changed since the last one, or
the root is gone.

Optional:
  --flake=<dir>      The flake whose checks are rooted (default: \$PRJ_ROOT,
                     else the current directory).
  --system=<system>  Default: $ROOT_CHECK_DEPENDENCIES_SYSTEM.
  --force            Refresh even when nothing changed.
  --background       Return at once and refresh in a detached process,
                     logging to the root's path with .log appended.
  -h, --help         Show this help and exit.
EOF
}

flake=${PRJ_ROOT:-$PWD}
system=$ROOT_CHECK_DEPENDENCIES_SYSTEM
force=0
background=0
for arg in "$@"; do
  case "$arg" in
  --flake=*) flake=${arg#--flake=} ;;
  --system=*) system=${arg#--system=} ;;
  --force) force=1 ;;
  --background) background=1 ;;
  -h | --help)
    print_help
    exit 0
    ;;
  *)
    printf 'root-check-dependencies: unknown argument: %s\n' "$arg" >&2
    exit 2
    ;;
  esac
done

if ! common_dir=$(git -C "$flake" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  printf 'root-check-dependencies: %s is not in a git repository; nothing rooted\n' "$flake"
  exit 0
fi
state_dir=$common_dir/agent-skill-flake
link=$state_dir/check-dependencies
stamp_file=$link.stamp
log_file=$link.log
lock_dir=$link.lock
mkdir -p "$state_dir"

# The files a check's dependencies come from: the flake's Nix code and the
# lock files of its inputs and of the languages it builds. Hashing their
# contents, not the commit, skips a refresh for a change to anything else.
input_files() {
  git -C "$flake" ls-files -z --cached --others --exclude-standard -- \
    '*.nix' '*.lock' '*go.sum' '*Package.resolved' '*package-lock.json' '*pnpm-lock.yaml' |
    while IFS= read -r -d '' file; do
      [ -f "$flake/$file" ] && printf '%s\n' "$file"
    done | LC_ALL=C sort -u
}

stamp() {
  local files
  files=$(input_files)
  {
    printf 'system %s\nexpr %s\n' "$system" "$ROOT_CHECK_DEPENDENCIES_EXPR"
    if [ -n "$files" ]; then
      paste -d ' ' <(printf '%s\n' "$files" | git -C "$flake" hash-object --stdin-paths) \
        <(printf '%s\n' "$files")
    fi
  } | sha256sum | cut -d ' ' -f 1
}

current=$(stamp)
if [ "$force" = 0 ] && [ -e "$link" ] && [ "$(cat "$stamp_file" 2>/dev/null)" = "$current" ]; then
  printf 'root-check-dependencies: %s is up to date\n' "$link"
  exit 0
fi

if [ "$background" = 1 ]; then
  args=("--flake=$flake" "--system=$system")
  [ "$force" = 1 ] && args+=(--force)
  (nohup "$0" "${args[@]}" </dev/null >"$log_file" 2>&1 &)
  exit 0
fi

# One refresh at a time per repository; a lock whose process is gone is
# taken over.
if ! mkdir "$lock_dir" 2>/dev/null; then
  holder=$(cat "$lock_dir/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    printf 'root-check-dependencies: a refresh is already running (pid %s)\n' "$holder"
    exit 0
  fi
fi
printf '%s\n' "$$" >"$lock_dir/pid"
trap 'rm -f "$lock_dir/pid"; rmdir "$lock_dir" 2>/dev/null || true' EXIT

if [ "$(nix config show keep-outputs 2>/dev/null)" != true ]; then
  printf 'root-check-dependencies: keep-outputs is not true, so only the checks'"'"' derivations are kept, not their dependencies'"'"' outputs\n' >&2
fi

# Evaluation only. No local or remote build slots, so an import from
# derivation evaluates when its result is already in the store and fails
# the refresh otherwise, rather than building it.
if ! listing=$(nix eval --raw --max-jobs 0 --builders '' \
  "$flake#checks.$system" --apply "$(cat "$ROOT_CHECK_DEPENDENCIES_EXPR")"); then
  printf 'root-check-dependencies: evaluating %s#checks.%s failed; %s left as it was\n' \
    "$flake" "$system" "$link" >&2
  exit 1
fi
case "$listing" in
/*) ;;
*)
  printf 'root-check-dependencies: expected a store path, got: %s\n' "$listing" >&2
  exit 1
  ;;
esac

# --add-root replaces the link in one rename, so the superseded set loses
# its root at the moment the new one gains it.
nix-store --add-root "$link" --indirect --realise "$listing" >/dev/null
printf '%s\n' "$current" >"$stamp_file.tmp"
mv -f "$stamp_file.tmp" "$stamp_file"
printf 'root-check-dependencies: rooted %s check derivations at %s\n' \
  "$(wc -l <"$listing" | tr -d ' ')" "$link"
