print_help() {
  cat <<EOF
Usage: $app_name --scope=<personal|project|custom> [--root=<path>] \\
                 [--gcroots-dir=<path>]

Required:
  --scope=personal              Reconcile \$HOME/$personal_suffix
  --scope=project               Reconcile <project-root>/$project_suffix
  --scope=custom --root=<path>  Reconcile <path>

EOF
  print_project_layout_usage
  cat <<EOF
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

ensure_project_layout || exit 1
mkdir -p "$target_root"
gcroots_ok=1
if ! mkdir -p "$gcroots_dir" 2>/dev/null; then
  gcroots_ok=0
  printf 'WARNING: could not create %s; store paths may be GC-eligible\n' "$gcroots_dir" >&2
elif ! ensure_gc_root_record; then
  printf 'WARNING: could not write %s\n' "$(gc_root_record_path)" >&2
fi

# 1. Install / refresh each declared skill (idempotent).
#    keep_set doubles as the O(1) membership test the step-2 sweep uses to
#    skip declared entries (vs. a per-entry linear scan of a names list).
#    A skill whose path holds the project's own file or directory is
#    kept in keep_set but left unlinked, unrooted and out of the lock.
declare -A keep_set=()
declare -a linked_skills=()
for entry in "${skills_list[@]}"; do
  parse_skill_entry "$entry"
  keep_set["$skill_name"]=1

  ensure_symlink "$target_root/$skill_name" "$skill_subpath" 'reconciled (install)' || continue

  if [ "$gcroots_ok" = "1" ] && ! ensure_gc_root "$skill_name" "$store_path"; then
    printf 'WARNING: could not write GC root for %s\n' "$skill_name" >&2
  fi
  linked_skills+=("$entry")
done

# 1b. Link each declared preferences file beside the skills, GC-rooted
#     like a skill. A regular file already at that path is the project's
#     own, committed preferences: it is left alone, and kept out of both
#     the sweep and the lock, so the flake never removes or excludes it.
declare -a pref_entries=()
for entry in "${preferences_list[@]}"; do
  pref_file=${entry%%:*}
  pref_path=${entry#*:}
  keep_set["$pref_file"]=1
  ensure_symlink "$target_root/$pref_file" "$pref_path" 'reconciled (preferences)' || continue
  if [ "$gcroots_ok" = "1" ] && ! ensure_gc_root "$pref_file" "$pref_path"; then
    printf 'WARNING: could not write GC root for %s\n' "$pref_file" >&2
  fi
  pref_entries+=("$entry")
done

# 2. Sweep $target_root for managed entries NOT in the declared set.
#
# Ownership scoping: an entry the lock attributes to a *different*
# appName (installedBy set and != owner_app) belongs to a coexisting
# aggregate and is left alone — so multiple aggregates can share one
# target dir, each declaratively owning its own slice. An entry the
# lock attributes to *us* is swept, and so is another appName's entry
# from before installs recorded `managedBy` whose store path is gone
# (is_ours_broken_by_lock). An entry with no recorded owner
# (a stray with no lock entry) falls back to the lineage rule: swept
# iff its sentinel / GC root marks it ours.
#
# Only symlinks are swept. A file or directory the lock names as ours is
# one the project put in place of a link this flake made, such as a
# `<skill>.preferences.md` committed where a declared one used to be
# linked: it is kept, and only its GC root goes.
swept=0
if [ -d "$target_root" ]; then
  shopt -s nullglob
  for entry in "$target_root"/*; do
    name=$(basename "$entry")
    [ -n "${keep_set[$name]+x}" ] && continue

    installed_by=$(lock_installed_by "$name")
    if [ -n "$installed_by" ]; then
      if [ "$installed_by" = "${owner_app:-}" ] && [ ! -L "$entry" ]; then
        rm -f "$(gc_root_path "$name")"
        printf 'kept: %s is the project'"'"'s own file, not a link this flake made\n' "$entry"
      elif [ "$installed_by" = "${owner_app:-}" ]; then
        remove_skill_links "$name"
        printf 'reconciled (sweep): %s\n' "$entry"
        swept=$((swept + 1))
      elif is_ours_broken_by_lock "$entry"; then
        # A pre-`managedBy` entry whose store path is gone, often under an
        # appName since renamed: no owner can revive it. Its lock entry
        # goes too, since lock_replace_all keeps other appNames' entries.
        cleanup_skill_entry "$name"
        printf 'reconciled (sweep, broken): %s\n' "$entry"
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
if [ ${#linked_skills[@]} -gt 0 ]; then
  lock_replace_all "${linked_skills[@]}"
else
  lock_replace_all
fi
lock_replace_preferences "${pref_entries[@]}"
sync_project_excludes

printf '\n%d declared skill(s) installed; %d stray managed entr(y/ies) swept.\n' \
  "${#skills_list[@]}" "$swept"
