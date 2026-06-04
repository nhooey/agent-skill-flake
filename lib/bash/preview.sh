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

if wants_help "$@"; then
  print_help
  exit 0
fi

parse_scope_no_positionals "$@" || exit $?

printf '%s preview (no changes made)\n\n' "$display_name"
printf 'Target directory: %s\n\n' "$target_root"

count=0
for entry in "${skills_list[@]}"; do
  parse_skill_entry "$entry"
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
