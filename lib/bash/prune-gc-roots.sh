print_help() {
  cat <<EOF
Usage: $app_name [--search=<dir>]... [--gcroots-dir=<path>] [--delete]

Lists the per-user GC roots that no install target it can find still
owns, and with --delete removes them. A target dir that is gone, such
as a removed git worktree's skills dir, leaves its roots pointing at
live store paths, so no reap removes them, and they keep every skill
build they point at from garbage collection.

Optional:
  --search=<dir>        Look for install targets, the dirs holding a
                        .agent-skill-flake-lock.json, under <dir> as
                        well as under \$HOME. Repeatable. Skips
                        \$HOME/Library and every .Trash, .git and
                        node_modules dir.
  --gcroots-dir=<path>  Override per-user GC-roots dir
                        (default: /nix/var/nix/gcroots/per-user/\$USER)
  --delete              Remove what the dry run lists.
  -h, --help            Show this help and exit.

A target's record of a skill, $GC_SHARED_SUBDIR/targets/<tag>/<name>, or
its flat root, ${GC_ROOT_PREFIX}<tag>-<name>, stays when a found target
has tag <tag> and links <name>, and so does its previous-build record
or root, the same name with ${GC_ROOT_PREVIOUS_SUFFIX}, while the current
one is there. A shared root, $GC_SHARED_SUBDIR/store/<store-path-name>,
goes when the last record using it goes. Targets are found by their
lock files, by the records of their dirs that installs leave beside
their roots ($GC_SHARED_SUBDIR/targets/<tag>/$GC_TARGET_RECORD and
${GC_ROOT_PREFIX}<tag>${GC_ROOT_RECORD_SUFFIX}), and at
\$HOME/$personal_suffix. Legacy shared roots (${GC_ROOT_PREFIX}<name>),
records of dirs that exist, and anything changed in the last hour, which
an install still running may own, stay too. Only ${GC_ROOT_PREFIX}* links
in the GC-roots dir and entries under its $GC_SHARED_SUBDIR dir are ever
removed: never a store path, and never anything else. It runs no garbage
collection. --delete takes the lock on $GC_SHARED_SUBDIR, then reads each
entry again, keeping any whose target's dir, skill link or current record
came back since the search; without the lock, it leaves $GC_SHARED_SUBDIR
alone.

A target the search can't reach looks gone, so its roots are listed
too: the summary names every dir the search couldn't read, and
--delete is refused when the search finds no lock file at all.
EOF
}

if wants_help "$@"; then
  print_help
  exit 0
fi

delete=0
search_dirs=("$HOME")
gcroots_dir="/nix/var/nix/gcroots/per-user/${USER:-$(id -un)}"
for arg in "$@"; do
  case "$arg" in
  --delete) delete=1 ;;
  --search=*) search_dirs+=("${arg#--search=}") ;;
  --gcroots-dir=*) gcroots_dir=${arg#--gcroots-dir=} ;;
  *)
    usage_error "unexpected argument: $arg"
    exit 2
    ;;
  esac
done
for dir in "${search_dirs[@]}"; do
  if [ ! -d "$dir" ]; then
    usage_error "no dir to search at $dir"
    exit 2
  fi
done
if [ ! -d "$gcroots_dir" ]; then
  printf '%s: no GC-roots dir at %s\n' "$app_name" "$gcroots_dir" >&2
  exit 1
fi
gc_root_tag=""
gc_layout_init

# plural <count> <word> -> "<count> <word>", with an s unless count is 1.
plural() {
  if [ "$1" -eq 1 ]; then
    printf '%d %s' "$1" "$2"
  else
    printf '%d %ss' "$1" "$2"
  fi
}

# 1. Read the GC-roots dir once, before looking for targets, so a root an
#    install writes during the search isn't judged against a search that
#    began before its target existed. Every entry is named by its path
#    relative to the GC-roots dir: a flat link's name, or
#    claude-skills/targets/<tag>/<name> for a record.
declare -a names=()
declare -A link_of=() mtime_of=() tag_of=() rec_name_of=() ino_of=() tag_mtime=() tag_stamp=()
while IFS=$'\t' read -r name mtime link; do
  names+=("$name")
  link_of[$name]=$link
  mtime_of[$name]=${mtime%.*}
done < <(find "$gcroots_dir" -mindepth 1 -maxdepth 1 -type l -name "${GC_ROOT_PREFIX}*" -printf '%f\t%T@\t%l\n' | sort)
# A record's own times are its build's anchor's, shared by every target,
# so a record's age is its target's records dir's: the time a record in it
# last came or went.
targets_rel=$GC_SHARED_SUBDIR/targets
if [ -d "$gc_targets_dir" ]; then
  while IFS=$'\t' read -r rel type mtime ino link; do
    if [ "$type" = d ]; then
      tag_mtime[$rel]=${mtime%.*}
      tag_stamp[$rel]=$mtime
      continue
    fi
    name=$targets_rel/$rel
    names+=("$name")
    tag_of[$name]=${rel%%/*}
    rec_name_of[$name]=${rel#*/}
    ino_of[$name]=$ino
    link_of[$name]=$link
  done < <(find "$gc_targets_dir" -mindepth 1 -maxdepth 2 -printf '%P\t%y\t%T@\t%i\t%l\n' | sort)
fi

# 2. Find the install targets: tag -> resolved dir.
declare -A target_of=()
add_target() {
  local dir
  dir=$(realpath -m -- "$1")
  target_of[$(gc_root_tag_for "$dir")]=$dir
}
if [ -d "$HOME/$personal_suffix" ]; then
  add_target "$HOME/$personal_suffix"
fi
for name in "${names[@]}"; do
  if [ -n "${tag_of[$name]+x}" ]; then
    if [ "${rec_name_of[$name]}" = "$GC_TARGET_RECORD" ] && [ -d "${link_of[$name]}" ]; then
      target_of[${tag_of[$name]}]=${link_of[$name]}
    fi
    continue
  fi
  gc_root_parse "$name"
  if [ "$gc_root_parsed_kind" = record ] && [ -d "${link_of[$name]}" ]; then
    target_of[$gc_root_parsed_tag]=${link_of[$name]}
  fi
done
printf 'Searching %s for install targets...\n' "${search_dirs[*]}" >&2
# find's complaints, one per dir it couldn't read, are kept for the summary.
search_errors=$(mktemp)
trap 'rm -f -- "$search_errors"' EXIT
locks_found=0
while IFS= read -r -d '' lock; do
  add_target "${lock%/*}"
  locks_found=$((locks_found + 1))
done < <(find "${search_dirs[@]}" \
  \( -path "$HOME/Library" -o -name .Trash -o -name .git -o -name node_modules \) -prune \
  -o -type f -name .agent-skill-flake-lock.json -print0 2>"$search_errors" || true)
if [ "$delete" = 1 ] && [ "$locks_found" -eq 0 ]; then
  printf '%s: the search found no lock file under %s; refusing --delete.\n' \
    "$app_name" "${search_dirs[*]}" >&2
  exit 1
fi

# entry_kind <name> -> sets kind (root, previous, record or legacy), tag
# and skill (the record's or root's skill or preferences file) for an
# entry of either layout.
entry_kind() {
  if [ -n "${tag_of[$1]+x}" ]; then
    tag=${tag_of[$1]}
    skill=${rec_name_of[$1]}
    case "$skill" in
    "$GC_TARGET_RECORD") kind=record ;;
    *"$GC_ROOT_PREVIOUS_SUFFIX")
      kind=previous
      skill=${skill%"$GC_ROOT_PREVIOUS_SUFFIX"}
      ;;
    *) kind=root ;;
    esac
  else
    gc_root_parse "$1"
    kind=$gc_root_parsed_kind
    tag=$gc_root_parsed_tag
    skill=$gc_root_parsed_name
  fi
}

# current_of <name> -> the name of the current record or root a
# previous-build one belongs beside.
current_of() {
  printf '%s' "${1%"$GC_ROOT_PREVIOUS_SUFFIX"}"
}

# young <name> <cutoff> -> 0 if the entry changed after <cutoff>.
young() {
  if [ -n "${tag_of[$1]+x}" ]; then
    [ "${tag_mtime[${tag_of[$1]}]:-0}" -gt "$2" ]
  else
    [ "${mtime_of[$1]}" -gt "$2" ]
  fi
}

# 3. Sort every entry into kept or removed.
grace_cutoff=$(($(date +%s) - 3600))
declare -a removals=() reasons=()
declare -A missing_tags=()
not_found=0 unlinked=0 orphan_previous=0 gone_records=0
kept_owned=0 kept_legacy=0 kept_records=0 kept_young=0
for name in "${names[@]}"; do
  entry_kind "$name"
  case "$kind" in
  legacy)
    kept_legacy=$((kept_legacy + 1))
    continue
    ;;
  record)
    if [ -d "${link_of[$name]}" ]; then
      kept_records=$((kept_records + 1))
      continue
    fi
    reason='install target gone'
    ;;
  root | previous)
    dir=${target_of[$tag]:-}
    if [ -z "$dir" ]; then
      reason='install target not found'
    elif [ ! -L "$dir/$skill" ]; then
      reason='skill no longer linked'
    elif [ "$kind" = previous ] && [ -z "${link_of[$(current_of "$name")]+x}" ]; then
      reason='previous build, current root gone'
    else
      kept_owned=$((kept_owned + 1))
      continue
    fi
    ;;
  esac
  if young "$name" "$grace_cutoff"; then
    kept_young=$((kept_young + 1))
    continue
  fi
  removals+=("$name")
  reasons+=("$reason")
done

# refresh_target <tag> — look again for the dir of the target with <tag>
# in its records of its dir, written since step 1 by an install into a
# dir made again at the same path.
refresh_target() {
  local rec link
  for rec in "$gc_targets_dir/$1/$GC_TARGET_RECORD" "$gcroots_dir/$GC_ROOT_PREFIX$1$GC_ROOT_RECORD_SUFFIX"; do
    link=$(readlink "$rec" 2>/dev/null) || continue
    if [ -d "$link" ]; then
      target_of[$1]=$link
    fi
  done
}

# still_removable <name> — 0 if the entry is still there and, read again
# now, still owned by no found target, setting live_reason to why.
still_removable() {
  local path=$gcroots_dir/$1 link dir
  [ -L "$path" ] || [ -f "$path" ] || return 1
  entry_kind "$1"
  [ -n "$tag" ] && refresh_target "$tag"
  case "$kind" in
  record)
    link=$(readlink "$path" 2>/dev/null) || link=""
    [ -d "$link" ] && return 1
    live_reason='install target gone'
    ;;
  root | previous)
    dir=${target_of[$tag]:-}
    if [ -z "$dir" ]; then
      live_reason='install target not found'
    elif [ ! -L "$dir/$skill" ]; then
      live_reason='skill no longer linked'
    elif [ "$kind" = previous ] && [ ! -L "${path%"$GC_ROOT_PREVIOUS_SUFFIX"}" ] &&
      [ ! -f "${path%"$GC_ROOT_PREVIOUS_SUFFIX"}" ]; then
      live_reason='previous build, current root gone'
    else
      return 1
    fi
    ;;
  *) return 1 ;;
  esac
}

# 4. With --delete, take the shared layout's lock, then read each removal
#    again: drop it when its target's records dir changed since step 1,
#    as an install still running may own it, or when its target's dir,
#    the skill's link or the current record is back. Without the lock,
#    leave the shared layout alone.
kept_changed=0 kept_unlocked=0
if [ "$delete" = 1 ]; then
  locked=0
  if [ -d "$gc_shared_dir" ]; then
    if gc_roots_lock; then
      locked=1
    else
      printf '%s: could not lock %s; leaving its records.\n' "$app_name" "$gc_shared_dir" >&2
    fi
  fi
  declare -A tag_stamp_now=()
  if [ "$locked" = 1 ]; then
    while IFS=$'\t' read -r tag mtime; do
      tag_stamp_now[$tag]=$mtime
    done < <(find "$gc_targets_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\t%T@\n')
  fi
  declare -a kept_removals=() kept_reasons=()
  for name in "${removals[@]}"; do
    if [ -n "${tag_of[$name]+x}" ]; then
      if [ "$locked" != 1 ]; then
        kept_unlocked=$((kept_unlocked + 1))
        continue
      fi
      if [ "${tag_stamp_now[${tag_of[$name]}]:-}" != "${tag_stamp[${tag_of[$name]}]:-}" ]; then
        kept_changed=$((kept_changed + 1))
        continue
      fi
    fi
    if ! still_removable "$name"; then
      kept_changed=$((kept_changed + 1))
      continue
    fi
    kept_removals+=("$name")
    kept_reasons+=("$live_reason")
  done
  removals=("${kept_removals[@]}")
  reasons=("${kept_reasons[@]}")
fi
for i in "${!reasons[@]}"; do
  entry_kind "${removals[$i]}"
  case "${reasons[$i]}" in
  'install target gone') gone_records=$((gone_records + 1)) ;;
  'install target not found')
    not_found=$((not_found + 1))
    missing_tags[$tag]=1
    ;;
  'skill no longer linked') unlinked=$((unlinked + 1)) ;;
  'previous build, current root gone') orphan_previous=$((orphan_previous + 1)) ;;
  esac
done

# 5. In a dry run, the shared roots the removals would leave without a
#    record: an anchor's link count is one more than its records, so it
#    goes when every record is among the removals. With --delete, step 6
#    lists those it removes, under the lock.
declare -a shared_removals=()
if [ "$delete" != 1 ] && [ -d "$gc_store_dir" ]; then
  declare -A dropping=()
  for name in "${removals[@]}"; do
    if [ -n "${ino_of[$name]+x}" ] && [ "${rec_name_of[$name]}" != "$GC_TARGET_RECORD" ]; then
      dropping[${ino_of[$name]}]=$((${dropping[${ino_of[$name]}]:-0} + 1))
    fi
  done
  while IFS=$'\t' read -r ino links base; do
    if [ "$((links - 1 - ${dropping[$ino]:-0}))" -le 0 ]; then
      shared_removals+=("${base%"$GC_ANCHOR_SUFFIX"}")
    fi
  done < <(find "$gc_store_dir" -mindepth 1 -maxdepth 1 -type f -name "*$GC_ANCHOR_SUFFIX" \
    -printf '%i\t%n\t%f\n' | sort -t$'\t' -k3)
fi

# 6. Remove, or list. Each path is a claude-skill-* link straight inside
#    the GC-roots dir or a record under claude-skills/targets; rm on a link
#    removes the link, never its target. The shared roots go after, those
#    whose anchor no record links any more, as the lock is held.
failed=0
if [ "$delete" = 1 ] && [ "${#removals[@]}" -gt 0 ]; then
  printf '%s\0' "${removals[@]/#/"$gcroots_dir/"}" | xargs -0 rm -f -- || true
fi
if [ "$delete" = 1 ] && [ -n "${gc_roots_lock_fd:-}" ]; then
  shared_removals=()
  while IFS= read -r base; do
    rm -f -- "$gc_store_dir/${base%"$GC_ANCHOR_SUFFIX"}" "$gc_store_dir/$base"
    shared_removals+=("${base%"$GC_ANCHOR_SUFFIX"}")
  done < <(find "$gc_store_dir" -mindepth 1 -maxdepth 1 -type f -name "*$GC_ANCHOR_SUFFIX" -links 1 \
    -printf '%f\n' | sort)
  find "$gc_targets_dir" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
fi
for i in "${!removals[@]}"; do
  path=$gcroots_dir/${removals[$i]}
  if [ "$delete" != 1 ]; then
    printf 'would remove (%s): %s\n' "${reasons[$i]}" "$path"
  elif [ -L "$path" ] || [ -f "$path" ]; then
    printf 'could not remove (%s): %s\n' "${reasons[$i]}" "$path" >&2
    failed=$((failed + 1))
  else
    printf 'removed (%s): %s\n' "${reasons[$i]}" "$path"
  fi
done
for base in "${shared_removals[@]}"; do
  if [ "$delete" = 1 ]; then
    printf 'removed (no record left): %s\n' "$gc_store_dir/$base"
  else
    printf 'would remove (no record left): %s\n' "$gc_store_dir/$base"
  fi
done

if [ "$delete" = 1 ]; then
  verb='Removed'
else
  verb='Would remove'
fi
printf '\n%s %d of %d records and %s* entries in %s:\n' \
  "$verb" "$((${#removals[@]} - failed))" "${#names[@]}" "$GC_ROOT_PREFIX" "$gcroots_dir"
printf '  %s of %s not found\n' "$(plural "$not_found" record)" "$(plural "${#missing_tags[@]}" 'install target')"
printf '  %s whose skill a found target no longer links\n' "$(plural "$unlinked" record)"
printf '  %s whose current record is gone\n' "$(plural "$orphan_previous" 'previous-build record')"
printf '  %s whose dir is gone\n' "$(plural "$gone_records" 'target-dir record')"
printf 'and %s no record uses any more.\n' "$(plural "${#shared_removals[@]}" 'shared root')"
printf 'Kept %d: %s of found install targets, %s, %s of live targets, %d younger than an hour, %d changed since the search, %d left unlocked.\n' \
  "$((kept_owned + kept_legacy + kept_records + kept_young + kept_changed + kept_unlocked))" \
  "$(plural "$kept_owned" record)" "$(plural "$kept_legacy" 'legacy shared root')" \
  "$(plural "$kept_records" 'target-dir record')" "$kept_young" "$kept_changed" "$kept_unlocked"
printf 'Found %s under %s, by lock file, record and personal scope.\n' \
  "$(plural "${#target_of[@]}" 'install target')" "${search_dirs[*]}"
unreadable=$(grep -c . "$search_errors" || true)
if [ "$unreadable" -gt 0 ]; then
  printf 'The search could not read %s; a target inside one looks gone:\n' \
    "$(plural "$unreadable" path)"
  sed 's/^/  /' "$search_errors"
fi
if [ "$delete" != 1 ] && [ "${#removals[@]}" -gt 0 ]; then
  printf 'Run again with --delete to remove them.\n'
fi
[ "$failed" -eq 0 ]
