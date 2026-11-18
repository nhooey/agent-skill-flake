# scope.bash — shared install-scope resolver.
#
# Caller responsibilities (set before sourcing):
#   personal_suffix   — agent profile's $HOME-relative skill dir
#                       (e.g. ".claude/skills" for claude-code)
#   project_suffix    — agent profile's project-root-relative skill dir
#                       (e.g. ".agents/skills" for claude-code)
#   app_name         — used in error/usage text
#
# Sets after a successful parse:
#   install_scope            — personal | project | custom
#   project_root             — the resolved project root (--scope=project
#                              only; empty otherwise)
#   target_root              — absolute path to install into
#   gcroots_dir              — absolute path to per-user GC-roots dir
#   gc_root_tag              — target_root's GC-root tag (see gc_root_tag_for)
#   scope_remaining_args[]   — argv with --scope/--root/--gcroots-dir stripped

# Install-layout constants — single source of truth for the on-disk shapes
# the verb scripts and the sourced helper modules (ownership/lock/sweep) all
# share. Sourced first, so they are in scope for every later module.
SKILLS_SHARE_SUBDIR="share/claude-skills"       # per-skill content path under a skill's store output
GC_ROOT_PREFIX="claude-skill-"                  # per-user GC-root filename prefix
GC_ROOT_TAG_LEN=12                              # hex chars of the target-dir hash in a root's name
GC_ROOT_RECORD_SUFFIX=".target"                 # suffix of the link naming a tag's target dir
SENTINEL_FILE=".agent-skill-flake-managed.json" # per-install provenance marker

# GC roots. Every install target (the user scope, each project's skill
# dir, each custom root) keeps its own per-user GC root per skill, named
#   <gcroots_dir>/claude-skill-<tag>-<name>
# where <tag> is the first GC_ROOT_TAG_LEN hex chars of the sha256 of the
# target dir's resolved absolute path. A root name shared by every target
# would let the last target to install a skill take the root, leaving the
# other targets' links pointing at unrooted store paths.
#
# Beside a target's roots, install and reconcile keep a record,
#   <gcroots_dir>/claude-skill-<tag>.target -> <resolved target dir>
# since the tag alone can't name its dir. Target dirs come and go, a git
# worktree's skills dir with each worktree, and their roots point at live
# store paths, so nothing else marks them as orphans: lineage_sweep drops
# a target's roots once its record points at a dir that is gone. Nix
# ignores the record, a link to a directory outside the store.
#
# A root named `claude-skill-<name>`, with no tag, is the legacy shared
# form. Ownership checks still accept it; nothing here creates it, and only
# lineage_sweep removes it, once no other root can depend on it.

# gc_root_tag_for <dir> -> the tag for <dir>. Symlinks are resolved (macOS
# /tmp -> /private/tmp) and a not-yet-created dir resolves through its
# existing ancestors, so the tag is the same before and after mkdir.
gc_root_tag_for() {
  local resolved
  resolved=$(realpath -m -- "$1")
  printf '%s' "$resolved" | sha256sum | cut -c1-"$GC_ROOT_TAG_LEN"
}

# gc_root_path <name> [<tag>] -> the root for <name> in the target with
# <tag> (default: this run's target_root).
gc_root_path() {
  printf '%s/%s%s-%s' "$gcroots_dir" "$GC_ROOT_PREFIX" "${2:-$gc_root_tag}" "$1"
}

# legacy_gc_root_path <name> -> the legacy, target-shared root for <name>.
legacy_gc_root_path() {
  printf '%s/%s%s' "$gcroots_dir" "$GC_ROOT_PREFIX" "$1"
}

# gc_root_record_path -> this run's target's record.
gc_root_record_path() {
  printf '%s/%s%s%s' "$gcroots_dir" "$GC_ROOT_PREFIX" "$gc_root_tag" "$GC_ROOT_RECORD_SUFFIX"
}

# gc_root_parse <root-filename> -> sets gc_root_parsed_kind (root, record
# or legacy), gc_root_parsed_tag (empty for the legacy form) and
# gc_root_parsed_name (empty for a record). Returns 1 if the filename
# lacks the prefix.
gc_root_parse() {
  local rest
  case "$1" in
  "$GC_ROOT_PREFIX"*) rest=${1#"$GC_ROOT_PREFIX"} ;;
  *) return 1 ;;
  esac
  if [[ $rest =~ ^([0-9a-f]{$GC_ROOT_TAG_LEN})-(.+)$ ]]; then
    gc_root_parsed_kind=root
    gc_root_parsed_tag=${BASH_REMATCH[1]}
    gc_root_parsed_name=${BASH_REMATCH[2]}
  elif [[ $rest =~ ^([0-9a-f]{$GC_ROOT_TAG_LEN})"$GC_ROOT_RECORD_SUFFIX"$ ]]; then
    gc_root_parsed_kind=record
    gc_root_parsed_tag=${BASH_REMATCH[1]}
    gc_root_parsed_name=""
  else
    gc_root_parsed_kind=legacy
    gc_root_parsed_tag=""
    gc_root_parsed_name=$rest
  fi
}

# ensure_gc_root_record — point this target's record at its resolved dir,
# which must already exist. Returns 1 if the record can't be written.
ensure_gc_root_record() {
  local record dir
  record=$(gc_root_record_path)
  dir=$(realpath -m -- "$target_root")
  # A dir inside the store gets no record: Nix would take a link to it
  # for a root, keeping the dir, and so the record, alive for good.
  case "$dir" in
  "${NIX_STORE_DIR:-/nix/store}"/*) return 0 ;;
  esac
  [ "$(readlink "$record" 2>/dev/null)" = "$dir" ] && return 0
  ln -sfn "$dir" "$record" 2>/dev/null
}

# ensure_gc_root <name> <store-path> [announce] — point this target's root
# for <name> at <store-path>; with "announce", print a change as
# "GC root: <root> -> <store-path>". Returns 1 if the root can't be written.
ensure_gc_root() {
  local root
  root=$(gc_root_path "$1")
  [ "$(readlink "$root" 2>/dev/null)" = "$2" ] && return 0
  ln -sfn "$2" "$root" 2>/dev/null || return 1
  if [ "${3:-}" = announce ]; then
    printf 'GC root: %s -> %s\n' "$root" "$2"
  fi
}

# Print "<app_name>: <msg>" then the standard "See --help" pointer to stderr —
# the shared shape behind every verb's argv-validation error.
usage_error() {
  printf '%s: %s\n' "$app_name" "$1" >&2
  printf '  See `%s --help` for usage.\n' "$app_name" >&2
}

# Split a `name:store_path` skills_list entry into globals: sets skill_name,
# store_path, and the derived skill_subpath (the installed content dir).
parse_skill_entry() {
  skill_name=${1%%:*}
  store_path=${1#*:}
  skill_subpath="${store_path}/${SKILLS_SHARE_SUBDIR}/${skill_name}"
}

# Walk up from $PWD looking for .git/ (preferred) or flake.nix (fallback).
# Echoes the project root and returns 0; returns 1 if not found.
find_project_root() {
  local git_root
  if git_root=$(git rev-parse --show-toplevel 2>/dev/null); then
    if [ -n "$git_root" ]; then
      printf '%s' "$git_root"
      return 0
    fi
  fi
  local dir="$PWD"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/flake.nix" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

# Parse --scope/--root/--gcroots-dir out of the argv. Other args pass
# through unchanged into the global `scope_remaining_args` array (the
# caller restores them with `set -- "${scope_remaining_args[@]}"`).
parse_scope_args() {
  scope_remaining_args=()
  local scope="" root="" gcroots=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --scope=*) scope="${1#--scope=}" ;;
    --scope)
      if [ $# -lt 2 ]; then
        printf '%s: --scope requires a value (personal|project|custom)\n' "$app_name" >&2
        return 2
      fi
      scope="$2"
      shift
      ;;
    --root=*) root="${1#--root=}" ;;
    --root)
      if [ $# -lt 2 ]; then
        printf '%s: --root requires a path\n' "$app_name" >&2
        return 2
      fi
      root="$2"
      shift
      ;;
    --gcroots-dir=*) gcroots="${1#--gcroots-dir=}" ;;
    --gcroots-dir)
      if [ $# -lt 2 ]; then
        printf '%s: --gcroots-dir requires a path\n' "$app_name" >&2
        return 2
      fi
      gcroots="$2"
      shift
      ;;
    *) scope_remaining_args+=("$1") ;;
    esac
    shift
  done

  if [ -z "$scope" ]; then
    usage_error '--scope is required (one of: personal, project, custom)'
    return 2
  fi

  install_scope="$scope"
  project_root=""
  case "$scope" in
  personal)
    if [ -n "$root" ]; then
      printf '%s: --root is only valid with --scope=custom (got --scope=personal)\n' "$app_name" >&2
      return 2
    fi
    target_root="$HOME/$personal_suffix"
    ;;
  project)
    if [ -n "$root" ]; then
      printf '%s: --root is only valid with --scope=custom (got --scope=project)\n' "$app_name" >&2
      return 2
    fi
    local proj
    if ! proj=$(find_project_root); then
      printf '%s: --scope=project but no project root found above PWD (%s).\n' "$app_name" "$PWD" >&2
      printf '  Searched for .git/ (preferred) or flake.nix (fallback).\n' >&2
      printf '  Use --scope=custom --root=<path> to install to an arbitrary directory.\n' >&2
      return 1
    fi
    project_root="$proj"
    target_root="$proj/$project_suffix"
    ;;
  custom)
    if [ -z "$root" ]; then
      printf '%s: --scope=custom requires --root=<path>\n' "$app_name" >&2
      return 2
    fi
    target_root="$root"
    ;;
  *)
    printf '%s: --scope must be personal, project, or custom (got: %s)\n' "$app_name" "$scope" >&2
    return 2
    ;;
  esac

  if [ -n "$gcroots" ]; then
    gcroots_dir="$gcroots"
  else
    gcroots_dir="/nix/var/nix/gcroots/per-user/$USER"
  fi
  gc_root_tag=$(gc_root_tag_for "$target_root")
}

# parse_scope_args + require an otherwise-empty argv. The verbs that take no
# positionals (reconcile, reap, preview) call this; a leftover positional is a
# hard usage error. On success the scope globals are set and argv is empty.
parse_scope_no_positionals() {
  parse_scope_args "$@" || return $?
  set -- "${scope_remaining_args[@]}"
  if [ $# -gt 0 ]; then
    usage_error "unexpected positional argument: $1"
    return 2
  fi
}

# Usage block shared by every app's --help. Prints to stdout.
print_scope_usage() {
  cat <<EOF
Install-scope flags (required):
  --scope=personal              Install at \$HOME/$personal_suffix
  --scope=project               Walk up from \$PWD for .git/ (preferred)
                                or flake.nix; install at
                                <project-root>/$project_suffix.
                                Hard error if no project root is found.
  --scope=custom --root=<path>  Install at <path> verbatim.

Other flags:
  --gcroots-dir=<path>          Override per-user GC-roots dir
                                (default: /nix/var/nix/gcroots/per-user/\$USER)
EOF
}

# True (0) if argv contains -h or --help. Each app short-circuits to its
# own print_help on this, before scope parsing, so the help text is
# obtainable without picking a scope.
wants_help() {
  local arg
  for arg in "$@"; do
    case "$arg" in
    -h | --help) return 0 ;;
    esac
  done
  return 1
}

# Idempotently point symlink $1 at the literal target $2, announcing the
# change as "$3: $1 -> $2" only when one was made. Direct `readlink`
# (no -f) compares the link's literal target, so an already-correct link
# is left untouched and silent — the install/reconcile no-op fast path.
# Only a symlink is ever replaced: a file or directory at $1 is the
# project's own, so it is left as it is, with a warning, and the call
# returns 1.
ensure_symlink() {
  local link=$1 dest=$2 label=$3
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    printf 'WARNING: %s is the project'"'"'s own file; not replacing it with a link\n' "$link" >&2
    return 1
  fi
  if [ "$(readlink "$link" 2>/dev/null)" != "$dest" ]; then
    rm -f "$link"
    ln -sfn "$dest" "$link"
    printf '%s: %s -> %s\n' "$label" "$link" "$dest"
  fi
}
