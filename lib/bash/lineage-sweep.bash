# lineage-sweep.bash — the shared target-dir sweep behind `reap` and `purge`.
#
# Both verbs remove entries this flake-skills lineage owns
# (managedBy == $upstream_url) from $target_root, then prune orphan GC
# roots. They differ ONLY in which managed entries qualify in pass 1:
#   reap  → only entries whose store path was GC'd      (is_ours_broken)
#   purge → every lineage entry, live or broken
# The caller encodes that as an `entry_predicate <entry>` function; the
# walk, removal, dry-run handling, GC-root pruning, counting, and summary
# are shared here so the two verbs can't drift. Both verbs key on lineage,
# not appName — that is what lets purge clear orphans whose installing hook
# is already gone.
#
# Caller contract (set/define before calling lineage_sweep):
#   $target_root $gcroots_dir $upstream_url  — from scope.bash + extraEnv
#   $sweep_label                             — past tense, e.g. "reaped"
#   $sweep_verb                              — imperative, e.g. "reap"
#   $dry_run                                 — "1" prints without removing
#   entry_predicate <entry>                  — returns 0 if <entry> qualifies
# Requires ownership.bash + lock.bash already sourced (is_ours_*,
# cleanup_skill_entry, lock_remove).

lineage_sweep() {
  local entry name gc target swept=0

  # 1. Walk $target_root/* — remove qualifying managed entries (and, via
  #    cleanup_skill_entry, their GC root + lock entry).
  if [ -d "$target_root" ]; then
    shopt -s nullglob
    for entry in "$target_root"/*; do
      entry_predicate "$entry" || continue
      name=$(basename "$entry")
      if [ "$dry_run" = "1" ]; then
        printf 'would %s: %s\n' "$sweep_verb" "$entry"
      else
        cleanup_skill_entry "$name"
        printf '%s: %s\n' "$sweep_label" "$entry"
      fi
      swept=$((swept + 1))
    done
  fi

  # 2. Walk $gcroots_dir/claude-skill-* — prune orphan GC roots whose
  #    store-path target no longer exists in the store.
  if [ -d "$gcroots_dir" ]; then
    shopt -s nullglob
    for gc in "${gcroots_dir}/${GC_ROOT_PREFIX}"*; do
      [ -L "$gc" ] || continue
      target=$(readlink "$gc")
      [ -e "$target" ] && continue
      name=${gc##*/"${GC_ROOT_PREFIX}"}
      if [ "$dry_run" = "1" ]; then
        printf 'would %s GC root (target gone): %s\n' "$sweep_verb" "$gc"
      else
        rm -f "$gc"
        lock_remove "$name"
        printf '%s GC root (target gone): %s\n' "$sweep_label" "$gc"
      fi
      swept=$((swept + 1))
    done
  fi

  if [ "$dry_run" = "1" ]; then
    printf '\n%d entr(y/ies) would be %s (managedBy=%s).\n' "$swept" "$sweep_label" "$upstream_url"
  else
    printf '\n%d entr(y/ies) %s (managedBy=%s).\n' "$swept" "$sweep_label" "$upstream_url"
  fi
}
