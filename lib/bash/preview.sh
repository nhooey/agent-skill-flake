print_help() {
  cat <<EOF
Usage: $app_name --scope=<personal|project|custom> [--root=<path>] \\
                 [--gcroots-dir=<path>]

Required:
  --scope=personal              Preview install at \$HOME/$personal_suffix
  --scope=project               Preview install at <project-root>/$project_suffix
  --scope=custom --root=<path>  Preview install at <path>

Optional:
  --gcroots-dir=<path>          (Accepted for symmetry with install/uninstall;
                                preview makes no GC-root changes.)
  -h, --help                    Show this help and exit.

Read-only listing of what an install with the same --scope would write.
No files are created or removed.
EOF
}

for arg in "$@"; do
  case "$arg" in
  -h | --help)
    print_help
    exit 0
    ;;
  esac
done

parse_scope_args "$@" || exit $?
set -- "${scope_remaining_args[@]}"
if [ $# -gt 0 ]; then
  printf '%s: unexpected positional argument: %s\n' "$app_name" "$1" >&2
  printf '  See `%s --help` for usage.\n' "$app_name" >&2
  exit 2
fi

printf '%s preview (no changes made)\n\n' "$display_name"
printf 'Target directory: %s\n\n' "$target_root"

count=0
for entry in "${skills_list[@]}"; do
  skill_name=${entry%%:*}
  store_path=${entry#*:}
  skill_subpath="$store_path/share/claude-skills/$skill_name"
  size=$(du -shL "$skill_subpath" 2>/dev/null | cut -f1)
  printf '  %s  (%s)\n' "$skill_name" "$size"
  find -L "$skill_subpath" -mindepth 1 ! -type d | sed "s|^$skill_subpath/|      |"
  count=$((count + 1))
done

printf '\n%d skill(s) total.\n' "$count"
printf '\nTo install (default — symlink + GC root):\n'
printf "  nix run '.#install' -- --scope=%s\n" "personal"
printf '\nTo install via nix profile (shows up in nix profile list):\n'
printf "  nix run '.#install' -- --scope=%s --profile\n" "personal"
printf '\n(preview only — no files were written)\n'
