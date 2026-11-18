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

A root ${GC_ROOT_PREFIX}<tag>-<name> stays when a found target has tag
<tag> and links <name>. Targets are found by their lock files, by the
records (${GC_ROOT_PREFIX}<tag>${GC_ROOT_RECORD_SUFFIX}) installs leave
beside their roots, and at \$HOME/$personal_suffix. Legacy shared roots
(${GC_ROOT_PREFIX}<name>), records of dirs that exist, and anything
changed in the last hour, which an install still running may own, stay
too. Only ${GC_ROOT_PREFIX}* links in the GC-roots dir are ever removed:
never a store path, and never anything else. It runs no garbage
collection.

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
#    began before its target existed.
declare -a names=()
declare -A link_of=() mtime_of=()
while IFS=$'\t' read -r name mtime link; do
  names+=("$name")
  link_of[$name]=$link
  mtime_of[$name]=${mtime%.*}
done < <(find "$gcroots_dir" -mindepth 1 -maxdepth 1 -type l -name "${GC_ROOT_PREFIX}*" -printf '%f\t%T@\t%l\n' | sort)

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

# 3. Sort every entry into kept or removed.
grace_cutoff=$(($(date +%s) - 3600))
declare -a removals=() reasons=()
declare -A missing_tags=()
not_found=0 unlinked=0 gone_records=0
kept_owned=0 kept_legacy=0 kept_records=0 kept_young=0
for name in "${names[@]}"; do
  gc_root_parse "$name"
  case "$gc_root_parsed_kind" in
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
  root)
    dir=${target_of[$gc_root_parsed_tag]:-}
    if [ -z "$dir" ]; then
      reason='install target not found'
    elif [ ! -L "$dir/$gc_root_parsed_name" ]; then
      reason='skill no longer linked'
    else
      kept_owned=$((kept_owned + 1))
      continue
    fi
    ;;
  esac
  if [ "${mtime_of[$name]}" -gt "$grace_cutoff" ]; then
    kept_young=$((kept_young + 1))
    continue
  fi
  case "$reason" in
  'install target gone') gone_records=$((gone_records + 1)) ;;
  'install target not found')
    not_found=$((not_found + 1))
    missing_tags[$gc_root_parsed_tag]=1
    ;;
  'skill no longer linked') unlinked=$((unlinked + 1)) ;;
  esac
  removals+=("$name")
  reasons+=("$reason")
done

# 4. Remove, or list. Each path is a claude-skill-* link straight inside
#    the GC-roots dir; rm on a link removes the link, never its target.
failed=0
if [ "$delete" = 1 ] && [ "${#removals[@]}" -gt 0 ]; then
  printf '%s\0' "${removals[@]/#/"$gcroots_dir/"}" | xargs -0 rm -f -- || true
fi
for i in "${!removals[@]}"; do
  path=$gcroots_dir/${removals[$i]}
  if [ "$delete" != 1 ]; then
    printf 'would remove (%s): %s\n' "${reasons[$i]}" "$path"
  elif [ -L "$path" ]; then
    printf 'could not remove (%s): %s\n' "${reasons[$i]}" "$path" >&2
    failed=$((failed + 1))
  else
    printf 'removed (%s): %s\n' "${reasons[$i]}" "$path"
  fi
done

if [ "$delete" = 1 ]; then
  verb='Removed'
else
  verb='Would remove'
fi
printf '\n%s %d of %d %s* entries in %s:\n' \
  "$verb" "$((${#removals[@]} - failed))" "${#names[@]}" "$GC_ROOT_PREFIX" "$gcroots_dir"
printf '  %s of %s not found\n' "$(plural "$not_found" root)" "$(plural "${#missing_tags[@]}" 'install target')"
printf '  %s whose skill a found target no longer links\n' "$(plural "$unlinked" root)"
printf '  %s of install targets gone\n' "$(plural "$gone_records" record)"
printf 'Kept %d: %s of found install targets, %s, %s of live targets, %d younger than an hour.\n' \
  "$((kept_owned + kept_legacy + kept_records + kept_young))" \
  "$(plural "$kept_owned" root)" "$(plural "$kept_legacy" 'legacy shared root')" \
  "$(plural "$kept_records" record)" "$kept_young"
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
