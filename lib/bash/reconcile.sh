print_help() {
  cat <<EOF
Usage: $app_name --scope=<personal|project|custom> [--root=<path>] \\
                 [--gcroots-dir=<path>]

Required:
  --scope=personal              Reconcile \$HOME/$personal_suffix
  --scope=project               Reconcile <project-root>/$project_suffix
  --scope=custom --root=<path>  Reconcile <path>

Optional:
  --gcroots-dir=<path>          Override per-user GC-roots dir
                                (default: /nix/var/nix/gcroots/per-user/\$USER)
  -h, --help                    Show this help and exit.

Installs/refreshes every declared skill (idempotent), sweeps managed
entries not in the declared set, and rewrites the aggregate lock to
match the declared set exactly.
EOF
}

if wants_help "$@"; then
  print_help
  exit 0
fi

parse_scope_no_positionals "$@" || exit $?

mkdir -p "$target_root"
gcroots_ok=1
if ! mkdir -p "$gcroots_dir" 2>/dev/null; then
  gcroots_ok=0
  printf 'WARNING: could not create %s; store paths may be GC-eligible\n' "$gcroots_dir" >&2
fi

# 1. Install / refresh each declared skill (idempotent).
#    keep_set doubles as the O(1) membership test the step-2 sweep uses to
#    skip declared entries (vs. a per-entry linear scan of a names list).
declare -A keep_set=()
for entry in "${skills_list[@]}"; do
  parse_skill_entry "$entry"
  gcroot_target="${gcroots_dir}/${GC_ROOT_PREFIX}${skill_name}"

  ensure_symlink "$target_root/$skill_name" "$skill_subpath" 'reconciled (install)'

  if [ "$gcroots_ok" = "1" ] &&
    [ "$(readlink "$gcroot_target" 2>/dev/null)" != "$store_path" ]; then
    ln -sfn "$store_path" "$gcroot_target" ||
      printf 'WARNING: could not write GC root for %s\n' "$skill_name" >&2
  fi

  keep_set["$skill_name"]=1
done

# 2. Sweep $target_root for managed entries NOT in the declared set.
#
# Ownership scoping: an entry the lock attributes to a *different*
# appName (installedBy set and != owner_app) belongs to a coexisting
# aggregate and is left alone — so multiple aggregates can share one
# target dir, each declaratively owning its own slice. An entry the
# lock attributes to *us* is swept. An entry with no recorded owner
# (a stray with no lock entry) falls back to the lineage rule: swept
# iff its sentinel / GC root marks it ours.
swept=0
if [ -d "$target_root" ]; then
  shopt -s nullglob
  for entry in "$target_root"/*; do
    name=$(basename "$entry")
    [ -n "${keep_set[$name]+x}" ] && continue

    installed_by=$(lock_installed_by "$name")
    if [ -n "$installed_by" ]; then
      if [ "$installed_by" = "${owner_app:-}" ]; then
        remove_skill_links "$name"
        printf 'reconciled (sweep): %s\n' "$entry"
        swept=$((swept + 1))
      fi
      # else: owned by another appName — leave it for that owner.
      continue
    fi

    if is_ours_live "$entry" "$upstream_url"; then
      remove_skill_links "$name"
      printf 'reconciled (sweep): %s\n' "$entry"
      swept=$((swept + 1))
    elif is_ours_broken "$entry" "$gcroots_dir"; then
      remove_skill_links "$name"
      printf 'reconciled (sweep, broken): %s\n' "$entry"
      swept=$((swept + 1))
    fi
  done
fi

# 3. Rewrite the aggregate lock to match the declared set exactly.
#    Skills not in the declared set are dropped from the lock here
#    (their symlinks/GC roots were already removed in step 2).
if [ ${#skills_list[@]} -gt 0 ]; then
  lock_replace_all "${skills_list[@]}"
else
  lock_replace_all
fi

printf '\n%d declared skill(s) installed; %d stray managed entr(y/ies) swept.\n' \
  "${#keep_set[@]}" "$swept"
