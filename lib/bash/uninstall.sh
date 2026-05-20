# Help / arg parsing.
if [ $# -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
  cat <<EOF
Usage: $app_name [<skill-name>...]

Removes the install-side artifacts for each named skill:
  - \$target_root/<name>             (symlink into the Nix store)
  - \$gcroots_dir/claude-skill-<name> (per-user GC root)
  - the entry in \$target_root/.flake-skills-lock.json

Refuses to touch entries that aren't managed by this flake-skills
lineage (managedBy=$upstream_url).

With no arguments: uninstalls "$default_skill" (the only skill in
a single-skill flake). For multi-skill flakes, a name is required.

Note: skills installed with --profile must be removed from the
Nix profile separately (\`nix profile remove\`).

Environment:
  $env_var_name    override the install root (default: $install_root_default)
  NIX_GCROOTS_DIR    override the GC-roots dir (default: per-user dir)
EOF
  exit 0
fi

# No args + default exists → uninstall the default.
if [ $# -eq 0 ]; then
  if [ -n "$default_skill" ]; then
    set -- "$default_skill"
  else
    echo "$app_name: skill name required" >&2
    echo "Usage: $app_name <skill-name>..." >&2
    exit 2
  fi
fi

removed=0
skipped=0
for name in "$@"; do
  entry="$target_root/$name"
  if [ ! -L "$entry" ] && [ ! -e "$entry" ]; then
    printf 'skipped: %s is not installed\n' "$name" >&2
    skipped=$((skipped + 1))
    continue
  fi

  if is_ours_live "$entry" "$upstream_url" \
     || is_ours_broken "$entry" "$gcroots_dir"; then
    rm -f "$entry"
    rm -f "$gcroots_dir/claude-skill-$name"
    lock_remove "$name"
    printf 'uninstalled: %s\n' "$name"
    removed=$((removed + 1))
  else
    printf 'skipped: %s is not managed by %s\n' "$name" "$upstream_url" >&2
    skipped=$((skipped + 1))
  fi
done

printf '\n%d uninstalled, %d skipped.\n' "$removed" "$skipped"
# Exit non-zero if every requested name was skipped — the user
# probably typo'd or invoked uninstall on something they didn't
# install via this flake.
if [ "$removed" = "0" ] && [ "$skipped" -gt 0 ]; then
  exit 1
fi
