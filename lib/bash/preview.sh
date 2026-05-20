printf '%s preview (no changes made)\n\n' "$display_name"
printf 'Target directory: %s\n' "$target_root"
printf '  (override with %s)\n\n' "$env_var_name"

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
printf "  nix run '.#install'\n"
printf '\nTo install via nix profile (shows up in nix profile list):\n'
printf "  nix run '.#install' -- --profile\n"
printf '\n(preview only — no files were written)\n'
