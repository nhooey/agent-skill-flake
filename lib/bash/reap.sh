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

reaped=0

# 1. Walk $target_root/* — remove our managed entries whose symlink
#    target is gone. Live entries are kept (reconcile handles those).
if [ -d "$target_root" ]; then
  shopt -s nullglob
  for entry in "$target_root"/*; do
    if is_ours_broken "$entry" "$gcroots_dir"; then
      name=$(basename "$entry")
      cleanup_skill_entry "$name"
      printf 'reaped (broken target): %s\n' "$entry"
      reaped=$((reaped + 1))
    fi
  done
fi

# 2. Walk $gcroots_dir/claude-skill-* — remove orphan GC roots whose
#    store-path target no longer exists in the store.
if [ -d "$gcroots_dir" ]; then
  shopt -s nullglob
  for gc in "$gcroots_dir"/claude-skill-*; do
    [ -L "$gc" ] || continue
    target=$(readlink "$gc")
    if [ ! -e "$target" ]; then
      name=${gc##*/claude-skill-}
      rm -f "$gc"
      lock_remove "$name"
      printf 'reaped GC root (target gone): %s\n' "$gc"
      reaped=$((reaped + 1))
    fi
  done
fi

printf '\n%d entr(y/ies) reaped (managedBy=%s).\n' "$reaped" "$upstream_url"
