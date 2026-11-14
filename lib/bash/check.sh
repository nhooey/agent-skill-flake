print_help() {
  cat <<EOF
Usage: $app_name --scope=<personal|project|custom> [--root=<path>] \\
                 [--gcroots-dir=<path>]

Required:
  --scope=personal              Check \$HOME/$personal_suffix
  --scope=project               Check <project-root>/$project_suffix
  --scope=custom --root=<path>  Check <path>

Optional:
  --gcroots-dir=<path>          Override per-user GC-roots dir
                                (default: /nix/var/nix/gcroots/per-user/\$USER)
  -h, --help                    Show this help and exit.

Checks that every skill and preferences link agent-skill-flake installed
in the target (each entry of its lock file) has a GC root of this
target's own, $GC_ROOT_PREFIX<tag>-<name>, protecting its store path.
Links it didn't install, such as Home Manager's, are left out. Prints
one line per link that isn't rooted so and exits 1; prints nothing and
exits 0 when every link is. Read-only.
EOF
}

if wants_help "$@"; then
  print_help
  exit 0
fi

parse_scope_no_positionals "$@" || exit $?

store_dir=${NIX_STORE_DIR:-/nix/store}

# store_path_of <path> -> the <store_dir>/<hash>-<name> <path> lies in, or
# nothing when it lies outside the store.
store_path_of() {
  case "$1" in
  "$store_dir"/*)
    local rest=${1#"$store_dir"/}
    printf '%s/%s' "$store_dir" "${rest%%/*}"
    ;;
  esac
}

# Read the roots folder once: one find lists every root and its target,
# where a readlink per root would start thousands of processes.
declare -A root_store=() # root filename -> its target's store path
declare -A rooted_by=()  # store path -> the root filenames protecting it
if [ -d "$gcroots_dir" ]; then
  while IFS=$'\t' read -r root_name root_target; do
    # Inline rather than store_path_of: a subshell per root is the cost
    # this single read avoids.
    case "$root_target" in "$store_dir"/*) ;; *) continue ;; esac
    sp=${root_target#"$store_dir"/}
    sp=$store_dir/${sp%%/*}
    root_store[$root_name]=$sp
    rooted_by[$sp]+="${rooted_by[$sp]:+ }$root_name"
  done < <(find "$gcroots_dir" -mindepth 1 -maxdepth 1 -type l -name "$GC_ROOT_PREFIX*" -printf '%f\t%l\n')
fi

# The entries agent-skill-flake installed here, from the lock.
lock=$(lock_path)
installed=()
if [ -f "$lock" ]; then
  mapfile -t installed < <(jq -r '((.skills // {}) + (.preferences // {})) | keys[]' "$lock")
fi

problems=0
for name in "${installed[@]}"; do
  link=$target_root/$name
  [ -L "$link" ] || continue
  resolved=$(realpath -m -- "$link")
  sp=$(store_path_of "$resolved")
  [ -n "$sp" ] || continue

  expected=$(gc_root_path "$name")
  expected=${expected##*/}
  [ "${root_store[$expected]:-}" = "$sp" ] && continue

  problems=$((problems + 1))
  if [ -n "${rooted_by[$sp]:-}" ]; then
    printf 'wrongly rooted: %s -> %s: rooted by %s, not %s\n' \
      "$link" "$sp" "${rooted_by[$sp]}" "$expected"
  else
    printf 'unrooted: %s -> %s: no GC root; expected %s\n' "$link" "$sp" "$expected"
  fi
done

[ "$problems" -eq 0 ]
