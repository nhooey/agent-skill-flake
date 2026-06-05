print_help() {
  cat <<EOF
Usage: $app_name --scope=<personal|project|custom> [--root=<path>] \\
                 [--gcroots-dir=<path>] [<skill-name>...]

Required:
  --scope=personal              Operate on \$HOME/$personal_suffix
  --scope=project               Operate on <project-root>/$project_suffix
  --scope=custom --root=<path>  Operate on <path>

Optional:
  --gcroots-dir=<path>          Override per-user GC-roots dir
                                (default: /nix/var/nix/gcroots/per-user/\$USER)
  -h, --help                    Show this help and exit.

Removes the install-side artifacts for each named skill:
  - <target>/<name>                  (symlink into the Nix store)
  - <gcroots>/claude-skill-<name>    (per-user GC root)
  - the entry in <target>/.agent-skill-flake-lock.json

Refuses to touch entries that aren't managed by this agent-skill-flake
lineage (managedBy=$upstream_url).

With no positional args: uninstalls "$default_skill" (the default
single skill). For multi-skill flakes the default is empty, and a name
is required.

Note: skills installed with --profile must be removed from the Nix
profile separately (\`nix profile remove\`).
EOF
}

if wants_help "$@"; then
  print_help
  exit 0
fi

parse_scope_args "$@" || exit $?
set -- "${scope_remaining_args[@]}"

# No positional args + a configured default → uninstall the default.
if [ $# -eq 0 ]; then
  if [ -n "$default_skill" ]; then
    set -- "$default_skill"
  else
    usage_error 'skill name required'
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

  if is_ours_live "$entry" "$upstream_url" ||
    is_ours_broken "$entry" "$gcroots_dir"; then
    cleanup_skill_entry "$name"
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
