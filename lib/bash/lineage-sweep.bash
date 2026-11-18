# lineage-sweep.bash — the shared target-dir sweep behind `reap` and `purge`.
#
# Both verbs remove entries this agent-skill-flake lineage owns
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
# cleanup_skill_entry, lock_remove, lock_store_path).

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

  # 2. Walk $gcroots_dir/claude-skill-* — prune GC roots that protect
  #    nothing:
  #      - every root and the record of a target whose record points at a
  #        dir that is gone (a removed worktree's skills dir, say);
  #      - any root whose store-path target no longer exists in the store;
  #      - a legacy shared root (claude-skill-<name>, no target tag) whose
  #        store path another, live target's root also points at.
  #    A live legacy root no per-target root covers is kept: some target
  #    not yet re-installed may still have only that root protecting it.
  #    The lock entry goes too only when the store path is gone and the
  #    root was this target's.
  if [ -d "$gcroots_dir" ]; then
    local -A link_of=() gone_tags=() tagged_targets=()
    local -a gc_names=()
    local gc_name reason lock_sp
    # One find lists every entry and its link, where a readlink per entry
    # would start tens of thousands of processes.
    while IFS=$'\t' read -r gc_name target; do
      gc_root_parse "$gc_name" || continue
      gc_names+=("$gc_name")
      link_of[$gc_name]=$target
      if [ "$gc_root_parsed_kind" = record ] && [ ! -e "$target" ]; then
        gone_tags[$gc_root_parsed_tag]=1
      fi
    done < <(find "$gcroots_dir" -mindepth 1 -maxdepth 1 -type l -name "${GC_ROOT_PREFIX}*" -printf '%f\t%l\n' | sort)
    for gc_name in "${gc_names[@]}"; do
      gc_root_parse "$gc_name"
      if [ "$gc_root_parsed_kind" = root ] && [ -z "${gone_tags[$gc_root_parsed_tag]+x}" ]; then
        tagged_targets[${link_of[$gc_name]}]=1
      fi
    done
    for gc_name in "${gc_names[@]}"; do
      gc_root_parse "$gc_name"
      gc=$gcroots_dir/$gc_name
      name=$gc_root_parsed_name
      target=${link_of[$gc_name]}
      if [ -n "$gc_root_parsed_tag" ] && [ -n "${gone_tags[$gc_root_parsed_tag]+x}" ]; then
        reason='install target gone'
      elif [ "$gc_root_parsed_kind" = record ]; then
        continue
      elif [ ! -e "$target" ]; then
        reason='target gone'
      elif [ "$gc_root_parsed_kind" = legacy ] && [ -n "${tagged_targets[$target]+x}" ]; then
        reason='legacy, superseded by a per-target root'
      else
        continue
      fi
      if [ "$dry_run" = "1" ]; then
        printf 'would %s GC root (%s): %s\n' "$sweep_verb" "$reason" "$gc"
      else
        rm -f "$gc"
        if [ "$reason" = 'target gone' ]; then
          if [ "$gc_root_parsed_tag" = "$gc_root_tag" ]; then
            lock_remove "$name"
          elif [ -z "$gc_root_parsed_tag" ]; then
            lock_sp=$(lock_store_path "$name")
            if [ "$lock_sp" = "$target" ]; then
              lock_remove "$name"
            fi
          fi
        fi
        printf '%s GC root (%s): %s\n' "$sweep_label" "$reason" "$gc"
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
