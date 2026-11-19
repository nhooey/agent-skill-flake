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
targets have been garbage-collected, orphan GC roots whose store-path
targets no longer exist with the records of them, every record and
flat root of an install target whose dir is gone, this target's
previous-build records (<gcroots>/claude-skills/targets/<target-hash>/
<name>.previous) and any previous-build flat root whose current one is
gone, every shared root (<gcroots>/claude-skills/store/<store-path-name>)
no record uses any more, and legacy claude-skill-<name> GC roots whose
store path a target's current record or flat root also protects. A
previous-build record beside its current record stays.
EOF
}

if wants_help "$@"; then
  print_help
  exit 0
fi

parse_scope_no_positionals "$@" || exit $?

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
gc_roots_unlock
sync_project_excludes
