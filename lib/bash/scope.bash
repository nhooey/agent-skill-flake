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
#   gc_shared_dir gc_store_dir gc_targets_dir gc_target_dir
#                            — the shared GC-root layout (see gc_layout_init)
#   scope_remaining_args[]   — argv with --scope/--root/--gcroots-dir stripped

# Install-layout constants — single source of truth for the on-disk shapes
# the verb scripts and the sourced helper modules (ownership/lock/sweep) all
# share. Sourced first, so they are in scope for every later module.
SKILLS_SHARE_SUBDIR="share/claude-skills"                 # per-skill content path under a skill's store output
GC_ROOT_PREFIX="claude-skill-"                            # flat GC-root filename prefix
GC_ROOT_TAG_LEN=12                                        # hex chars of the target-dir hash in a tag
GC_ROOT_RECORD_SUFFIX=".target"                           # suffix of a flat record naming a tag's target dir
GC_ROOT_PREVIOUS_SUFFIX=".previous"                       # suffix of a previous-build record or root
GC_SHARED_SUBDIR="claude-skills"                          # the shared layout's dir under the GC-roots dir
GC_TARGET_RECORD=".target"                                # a target's record of its own dir, in its records dir
GC_ANCHOR_SUFFIX=".refs"                                  # suffix of a shared root's anchor file
GC_LOCK_TIMEOUT=${AGENT_SKILL_FLAKE_GC_LOCK_TIMEOUT:-120} # seconds to wait for the shared layout's lock
SENTINEL_FILE=".agent-skill-flake-managed.json"           # per-install provenance marker

# GC roots. Identical builds share one GC root, keyed by store path, and
# every install target (the user scope, each project's skill dir, each
# custom root) keeps a record per skill pointing at it:
#
#   <gcroots_dir>/claude-skills/
#     lock                          flock(1) lock over everything below
#     store/<hash>-<name>           -> /nix/store/<hash>-<name>, the root
#     store/<hash>-<name>.refs      the anchor: a regular file holding the
#                                   store path, which records hard-link
#     targets/<tag>/.target         -> <resolved target dir>
#     targets/<tag>/<skill>         a hard link of the current build's anchor
#     targets/<tag>/<skill>.previous  a hard link of the previous build's anchor
#
# <tag> is the first GC_ROOT_TAG_LEN hex chars of the sha256 of the target
# dir's resolved absolute path. A record is a hard link of its build's
# anchor, so the anchor's link count is one more than the number of
# records using the root: a root goes, with its anchor, only when that
# count falls to 1, when no target's record uses it any more. Nix reads
# only the store/ links as roots; it skips the records and anchors,
# regular files whose names aren't valid store paths, and the .target
# links, which point at directories outside the store.
#
# A target keeps its current and previous builds of each skill only: when
# a new build replaces a record's, the replaced one moves to
# <skill>.previous, displacing the build before it. lineage_sweep drops
# its own target's previous-build records whose current record is gone,
# and prune-gc-roots every target's.
#
# Target dirs come and go, a git worktree's skills dir with each worktree,
# and their records point at live store paths, so nothing else marks them
# as orphans: lineage_sweep drops a target's records once its .target
# points at a dir that is gone, and with them every root no other record
# uses.
#
# Every change below claude-skills/, and every check an install makes
# before deciding there's nothing to change, happens under an exclusive
# flock(1) on its lock, taken once per run and released before the run
# starts programs that may outlive it (gc_roots_unlock). Runs of this
# revision therefore can't race a root away between reading an anchor's
# link count and removing it, nor remove a target's records while an
# install into it is checking them. A run that can't get the lock in
# GC_LOCK_TIMEOUT seconds (AGENT_SKILL_FLAKE_GC_LOCK_TIMEOUT) changes
# nothing below claude-skills/ for the rest of the run. Revisions before
# the shared layout take no lock, and never touch claude-skills/.
#
# Counting by link count needs the hard links kept: a copy of the GC-roots
# dir made without them (`cp -r`, macOS's `cp -a`, `rsync` without -H)
# splits each record from its anchor, and any run that drops a record of
# the same build, other than the record's own target's install,
# reconcile, reap or purge, takes the anchor for one no record uses.
# Those four relink their own target's records, current and
# previous-build, before they count (gc_target_relink), which repairs one
# target at a time.
#
# Flat roots straight in <gcroots_dir> are the layout that installs from
# agent-skill-flake revs pinned before this one write: per-target roots
#   claude-skill-<tag>-<name>, claude-skill-<tag>-<name>.previous
# with their record claude-skill-<tag>.target. They keep protecting their
# store paths until pruned: install and reconcile move a target's own flat
# roots into records (migrate_flat_gc_roots), each record written before
# its flat root goes, and lineage_sweep and prune-gc-roots prune flat
# roots by the rules they always had. A root named `claude-skill-<name>`,
# with no tag, is the legacy shared form. Ownership checks still accept
# it; nothing here creates it, and only lineage_sweep removes it, once no
# other root can depend on it.

# gc_root_tag_for <dir> -> the tag for <dir>. Symlinks are resolved (macOS
# /tmp -> /private/tmp) and a not-yet-created dir resolves through its
# existing ancestors, so the tag is the same before and after mkdir.
gc_root_tag_for() {
  local resolved
  resolved=$(realpath -m -- "$1")
  printf '%s' "$resolved" | sha256sum | cut -c1-"$GC_ROOT_TAG_LEN"
}

# gc_layout_init — set the shared layout's paths from gcroots_dir and
# gc_root_tag (empty when the caller has no target): gc_shared_dir,
# gc_store_dir, gc_targets_dir and gc_target_dir.
gc_layout_init() {
  gc_shared_dir=$gcroots_dir/$GC_SHARED_SUBDIR
  gc_store_dir=$gc_shared_dir/store
  gc_targets_dir=$gc_shared_dir/targets
  gc_target_dir=$gc_targets_dir/${gc_root_tag:-}
}

# gc_record_path <name> [<tag>] -> the record for <name> in the target with
# <tag> (default: this run's target_root).
gc_record_path() {
  printf '%s/%s/%s' "$gc_targets_dir" "${2:-$gc_root_tag}" "$1"
}

# gc_roots_lock — take the exclusive lock on the shared layout, once per
# run, holding it until gc_roots_unlock or the run's exit. Says so on
# stderr when it has to wait. Returns 1, with one warning per run, when
# the lock can't be opened or had within GC_LOCK_TIMEOUT seconds; every
# later call in the run then returns 1 at once.
gc_roots_lock() {
  [ -n "${gc_roots_lock_fd:-}" ] && return 0
  [ -z "${gc_roots_lock_failed:-}" ] || return 1
  if ! mkdir -p "$gc_store_dir" "$gc_targets_dir" "$gc_shared_dir/tmp" 2>/dev/null ||
    ! exec {gc_roots_lock_fd}>>"$gc_shared_dir/lock"; then
    unset gc_roots_lock_fd
    gc_roots_lock_failed=1
    printf 'WARNING: could not open %s\n' "$gc_shared_dir/lock" >&2
    return 1
  fi
  if flock -x -n "$gc_roots_lock_fd"; then
    return 0
  fi
  printf 'Waiting for %s...\n' "$gc_shared_dir/lock" >&2
  if ! flock -x -w "$GC_LOCK_TIMEOUT" "$gc_roots_lock_fd"; then
    exec {gc_roots_lock_fd}>&-
    unset gc_roots_lock_fd
    gc_roots_lock_failed=1
    printf 'WARNING: timed out waiting for %s\n' "$gc_shared_dir/lock" >&2
    return 1
  fi
}

# gc_roots_unlock — release the lock, before a run starts programs that
# may outlive it, such as git, whose fsmonitor daemon would otherwise
# inherit the lock's file descriptor and hold the lock.
gc_roots_unlock() {
  [ -n "${gc_roots_lock_fd:-}" ] || return 0
  exec {gc_roots_lock_fd}>&-
  unset gc_roots_lock_fd
}

# gc_anchor_of <record> -> the anchor <record> is a hard link of, from the
# store path it holds; nothing for an empty or unreadable record.
gc_anchor_of() {
  local sp=""
  read -r sp <"$1" 2>/dev/null || true
  [ -n "$sp" ] && printf '%s/%s%s' "$gc_store_dir" "${sp##*/}" "$GC_ANCHOR_SUFFIX"
  return 0
}

# gc_shared_root_ensure <store-path> — under the lock: make the shared root
# and the anchor for <store-path>. Returns 1 if either can't be written.
gc_shared_root_ensure() {
  local sp=$1 root anchor tmp=$gc_shared_dir/tmp/$$
  root=$gc_store_dir/${1##*/}
  anchor=$root$GC_ANCHOR_SUFFIX
  if [ "$(readlink "$root" 2>/dev/null)" != "$sp" ]; then
    rm -f "$tmp"
    { ln -s "$sp" "$tmp" && mv -fT "$tmp" "$root"; } 2>/dev/null || {
      rm -f "$tmp"
      return 1
    }
  fi
  if [ ! -f "$anchor" ]; then
    rm -f "$tmp"
    { printf '%s\n' "$sp" >"$tmp" && mv -fT "$tmp" "$anchor"; } 2>/dev/null || {
      rm -f "$tmp"
      return 1
    }
  fi
}

# gc_record_link <record> <store-path> — under the lock, with the anchor
# made: make <record> a hard link of <store-path>'s anchor, replacing it
# in one rename. A rename onto a link of the same file does nothing and
# leaves the temporary link, so a record already right is left alone.
gc_record_link() {
  local rec=$1 anchor tmp=$gc_shared_dir/tmp/$$
  anchor=$gc_store_dir/${2##*/}$GC_ANCHOR_SUFFIX
  [ "$rec" -ef "$anchor" ] && return 0
  rm -f "$tmp"
  { ln "$anchor" "$tmp" && mv -fT "$tmp" "$rec"; } 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
}

# gc_target_relink — under the lock: make each of this target's records,
# current and previous-build, that a copy of the GC-roots dir split from
# its anchor a hard link of that anchor again, remaking the anchor and the
# root if they're gone. A record whose store path is gone is left to the
# sweeps.
gc_target_relink() {
  local rec sp
  for rec in "$gc_target_dir"/*; do
    [ -f "$rec" ] || continue
    sp=""
    read -r sp <"$rec" 2>/dev/null || true
    if [ -z "$sp" ] || [ ! -e "$sp" ] || [ "$rec" -ef "$gc_store_dir/${sp##*/}$GC_ANCHOR_SUFFIX" ]; then
      continue
    fi
    if gc_shared_root_ensure "$sp"; then
      gc_record_link "$rec" "$sp" || true
    fi
  done
  return 0
}

# gc_anchor_release <anchor>... — under the lock: remove each anchor no
# record links any more (link count 1), with its root.
gc_anchor_release() {
  local anchor links
  for anchor in "$@"; do
    [ -f "$anchor" ] || continue
    links=$(stat -c %h -- "$anchor" 2>/dev/null) || continue
    [ "$links" -le 1 ] || continue
    rm -f -- "${anchor%"$GC_ANCHOR_SUFFIX"}" "$anchor"
  done
  return 0
}

# gc_record_remove <record>... — under the lock: remove each record, and
# each root no record uses any more.
gc_record_remove() {
  local rec
  local -a anchors=()
  for rec in "$@"; do
    [ -f "$rec" ] || continue
    anchors+=("$(gc_anchor_of "$rec")")
    rm -f -- "$rec"
  done
  gc_anchor_release "${anchors[@]}"
}

# flat_gc_root_path <name> [<tag>] -> the flat root for <name> in the
# target with <tag> (default: this run's target_root).
flat_gc_root_path() {
  printf '%s/%s%s-%s' "$gcroots_dir" "$GC_ROOT_PREFIX" "${2:-$gc_root_tag}" "$1"
}

# remove_gc_roots <name> — remove this target's current and previous-build
# records for <name>, every shared root no other record uses, and the
# target's flat roots for <name>. A lock that can't be had leaves the
# records, and so their roots, in place.
remove_gc_roots() {
  local rec flat
  rec=$(gc_record_path "$1")
  flat=$(flat_gc_root_path "$1")
  rm -f "$flat" "$flat$GC_ROOT_PREVIOUS_SUFFIX"
  if [ -f "$rec" ] || [ -f "$rec$GC_ROOT_PREVIOUS_SUFFIX" ]; then
    gc_roots_lock || return 0
    gc_record_remove "$rec" "$rec$GC_ROOT_PREVIOUS_SUFFIX"
  fi
  return 0
}

# legacy_gc_root_path <name> -> the legacy, target-shared root for <name>.
legacy_gc_root_path() {
  printf '%s/%s%s' "$gcroots_dir" "$GC_ROOT_PREFIX" "$1"
}

# gc_root_record_path -> this run's target's record of its own dir.
gc_root_record_path() {
  printf '%s/%s' "$gc_target_dir" "$GC_TARGET_RECORD"
}

# gc_root_parse <root-filename> -> parses a flat entry's name: sets
# gc_root_parsed_kind (root, previous, record or legacy),
# gc_root_parsed_tag (empty for the legacy form) and gc_root_parsed_name
# (the skill or preferences file; empty for a record). Returns 1 if the
# filename lacks the prefix. Neither a skill name nor a preferences file
# name ends in the previous suffix.
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
    case "$gc_root_parsed_name" in
    *"$GC_ROOT_PREVIOUS_SUFFIX")
      gc_root_parsed_kind=previous
      gc_root_parsed_name=${gc_root_parsed_name%"$GC_ROOT_PREVIOUS_SUFFIX"}
      ;;
    esac
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

# ensure_gc_root_record — point this target's record of its own dir at
# the resolved dir, which must already exist, relink the target's records
# that a copy split from their anchors (gc_target_relink), and move the
# target's flat roots into records. Returns 1 if the record can't be
# written.
#
# It takes the lock first, so a reap or prune deciding that this target's
# dir is gone, as it is when a worktree is removed and made again at the
# same path, finishes before the record is checked, or waits until it is
# written. Returns 1, with a warning naming what failed.
ensure_gc_root_record() {
  local record dir tmp=$gc_shared_dir/tmp/$$
  gc_roots_lock || return 1
  record=$(gc_root_record_path)
  dir=$(realpath -m -- "$target_root")
  # A dir inside the store gets no record: Nix would take a link to it
  # for a root, keeping the dir, and so the record, alive for good.
  case "$dir" in
  "${NIX_STORE_DIR:-/nix/store}"/*) ;;
  *)
    if [ "$(readlink "$record" 2>/dev/null)" != "$dir" ]; then
      rm -f "$tmp"
      if ! { mkdir -p "$gc_target_dir" && ln -s "$dir" "$tmp" && mv -fT "$tmp" "$record"; } 2>/dev/null; then
        rm -f "$tmp"
        printf 'WARNING: could not write %s\n' "$record" >&2
        return 1
      fi
    fi
    ;;
  esac
  gc_target_relink
  if ! migrate_flat_gc_roots; then
    printf 'WARNING: could not move every flat GC root of %s into records\n' "$target_root" >&2
    return 1
  fi
}

# migrate_flat_gc_roots — under the lock, with the target's record of its
# dir written: move this target's flat roots into records. A flat current
# root becomes the current record, replacing a different one as a new
# build would, and a flat previous-build root becomes the previous-build
# record unless one is there. Each record is written before its flat root
# goes, and a flat root whose record can't be written stays. Flat roots
# whose store path is gone just go. The flat record of the target's dir
# goes once none of the target's flat roots is left. Returns 1 if a flat
# root stays.
migrate_flat_gc_roots() {
  local flat name sp prefix=$gcroots_dir/$GC_ROOT_PREFIX$gc_root_tag status=0
  local -a flats=()
  for flat in "$prefix"-*; do
    [ -L "$flat" ] && flats+=("$flat")
  done
  if [ "${#flats[@]}" -gt 0 ]; then
    mkdir -p "$gc_target_dir" 2>/dev/null || return 1
  fi
  # Current roots first, so a previous-build root they displace is known.
  for flat in "${flats[@]}"; do
    case "$flat" in *"$GC_ROOT_PREVIOUS_SUFFIX") continue ;; esac
    name=${flat#"$prefix"-}
    sp=$(readlink "$flat") || continue
    if [ -e "$sp" ] && ! ensure_gc_root "$name" "$sp"; then
      status=1
      continue
    fi
    rm -f "$flat"
  done
  for flat in "${flats[@]}"; do
    case "$flat" in *"$GC_ROOT_PREVIOUS_SUFFIX") ;; *) continue ;; esac
    name=${flat#"$prefix"-}
    sp=$(readlink "$flat") || continue
    if [ -e "$sp" ] && [ ! -f "$gc_target_dir/$name" ] &&
      ! { gc_shared_root_ensure "$sp" && gc_record_link "$gc_target_dir/$name" "$sp"; }; then
      status=1
      continue
    fi
    rm -f "$flat"
  done
  for flat in "$prefix"-*; do
    [ -L "$flat" ] && return 1
  done
  rm -f "$prefix$GC_ROOT_RECORD_SUFFIX"
  return "$status"
}

# ensure_gc_root <name> <store-path> [announce] — point this target's
# record for <name> at <store-path>'s shared root, making the root if
# needed and moving the build it replaces, if that is still in the store,
# to the previous-build record; a root no record uses any more goes. With
# "announce", print a change as "GC root: <record> -> <store-path>".
# Returns 1 if a record can't be written; the current record is written
# even when the previous-build record can't be, since the link already
# points at the new build.
ensure_gc_root() {
  local name=$1 sp=$2 rec prev old="" status=0 tmp=$gc_shared_dir/tmp/$$ anchor
  local -a released=()
  rec=$gc_target_dir/$name
  prev=$rec$GC_ROOT_PREVIOUS_SUFFIX
  anchor=$gc_store_dir/${sp##*/}$GC_ANCHOR_SUFFIX
  # The lock comes before even the no-op check: a reap or prune holding
  # it may be about to remove this record, judging this target gone.
  gc_roots_lock || return 1
  if [ "$rec" -ef "$anchor" ] && [ -L "${anchor%"$GC_ANCHOR_SUFFIX"}" ]; then
    return 0
  fi
  mkdir -p "$gc_target_dir" 2>/dev/null || return 1
  if [ -f "$rec" ]; then
    read -r old <"$rec" 2>/dev/null || true
  fi
  gc_shared_root_ensure "$sp" || return 1
  if [ -n "$old" ] && [ "$old" != "$sp" ]; then
    if [ -e "$old" ]; then
      if [ ! "$prev" -ef "$rec" ]; then
        [ -f "$prev" ] && released+=("$(gc_anchor_of "$prev")")
        rm -f "$tmp"
        # The old build's anchor, not the record, which a copy may have
        # split from it; gc_shared_root_ensure makes it if it's missing.
        { gc_shared_root_ensure "$old" && ln "$gc_store_dir/${old##*/}$GC_ANCHOR_SUFFIX" "$tmp" &&
          mv -fT "$tmp" "$prev"; } 2>/dev/null || {
          rm -f "$tmp"
          status=1
        }
      fi
    else
      released+=("$(gc_anchor_of "$rec")")
    fi
  fi
  gc_record_link "$rec" "$sp" || return 1
  gc_anchor_release "${released[@]}"
  if [ "${3:-}" = announce ]; then
    printf 'GC root: %s -> %s\n' "$rec" "$sp"
  fi
  return "$status"
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
  gc_layout_init
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
