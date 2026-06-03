print_help() {
  cat <<EOF
Usage: $app_name --scope=<personal|project|custom> [--root=<path>] \\
                 [--gcroots-dir=<path>]

Required:
  --scope=personal              Reap \$HOME/$personal_suffix
  --scope=project               Reap <project-root>/$project_suffix
  --scope=custom --root=<path>  Reap <path>

Optional:
  --gcroots-dir=<path>          Override per-user GC-roots dir
                                (default: /nix/var/nix/gcroots/per-user/\$USER)
  -h, --help                    Show this help and exit.

Removes managed entries (managedBy=$upstream_url) whose symlink
targets have been garbage-collected, and orphan GC roots whose
store-path targets no longer exist.
EOF
}

if wants_help "$@"; then
  print_help
  exit 0
fi

parse_scope_args "$@" || exit $?
set -- "${scope_remaining_args[@]}"
if [ $# -gt 0 ]; then
  printf '%s: unexpected positional argument: %s\n' "$app_name" "$1" >&2
  printf '  See `%s --help` for usage.\n' "$app_name" >&2
  exit 2
fi

# reap qualifies only entries whose store path was garbage-collected;
# live entries are left for reconcile. The walk itself lives in the
# shared lineage-sweep.bash (purge reuses it with a wider predicate).
entry_predicate() {
  is_ours_broken "$1" "$gcroots_dir"
}
sweep_label='reaped'
sweep_verb='reap'
dry_run=0

lineage_sweep
