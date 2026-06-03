print_help() {
  cat <<EOF
Usage: $app_name --scope=<personal|project|custom> [--root=<path>] \\
                 [--gcroots-dir=<path>] [--dry-run] [-y|--yes]

Required:
  --scope=personal              Purge \$HOME/$personal_suffix
  --scope=project               Purge <project-root>/$project_suffix
  --scope=custom --root=<path>  Purge <path>

Optional:
  --gcroots-dir=<path>          Override per-user GC-roots dir
                                (default: /nix/var/nix/gcroots/per-user/\$USER)
  --dry-run                     List what would be removed; change nothing.
  -y, --yes                     Skip the confirmation prompt.
  -h, --help                    Show this help and exit.

Removes EVERY skill this flake-skills lineage (managedBy=$upstream_url)
installed under the target dir — live or broken — regardless of which
hook/appName installed it, and prunes orphan GC roots. Unlike reconcile,
purge ignores any declared set; unlike uninstall, it needs no skill names.

The scope-uniform teardown escape hatch: the SAME command clears the
user-global and project dirs (only --scope differs), and it can run
transiently (e.g. \`nix run $upstream_url#purge -- --scope=personal\`)
to clear a scope before removing all references to flake-skills — when
no reconcile hook is left to converge the dir to empty.

Leaves entries NOT managed by this lineage untouched.
EOF
}

if wants_help "$@"; then
  print_help
  exit 0
fi

parse_scope_args "$@" || exit $?
set -- "${scope_remaining_args[@]}"

dry_run=0
assume_yes=0
while [ $# -gt 0 ]; do
  case "$1" in
  --dry-run) dry_run=1 ;;
  -y | --yes) assume_yes=1 ;;
  *)
    printf '%s: unexpected argument: %s\n' "$app_name" "$1" >&2
    printf '  See `%s --help` for usage.\n' "$app_name" >&2
    exit 2
    ;;
  esac
  shift
done

# purge qualifies every entry this lineage owns — live or broken — so a
# scope can be cleared even after the hook that installed its skills is
# gone. The walk + GC-root pruning are shared with reap via lineage_sweep.
entry_predicate() {
  is_ours_live "$1" "$upstream_url" || is_ours_broken "$1" "$gcroots_dir"
}
sweep_label='purged'
sweep_verb='purge'

# Destructive and set-independent: confirm before removing. --dry-run and
# --yes both skip the prompt; a non-interactive run without either refuses
# rather than hang or surprise (pass --yes in scripts/CI, --dry-run to peek).
if [ "$dry_run" != "1" ] && [ "$assume_yes" != "1" ]; then
  if [ ! -t 0 ]; then
    printf '%s: refusing to purge non-interactively without --yes (or use --dry-run).\n' \
      "$app_name" >&2
    exit 2
  fi
  printf 'About to remove ALL flake-skills-managed skills (managedBy=%s)\n' "$upstream_url" >&2
  printf 'from %s, regardless of which hook installed them.\n' "$target_root" >&2
  printf 'Proceed? [y/N] ' >&2
  read -r reply
  case "$reply" in
  y | Y | yes | Yes | YES) ;;
  *)
    printf 'Aborted; nothing removed.\n' >&2
    exit 1
    ;;
  esac
fi

lineage_sweep
