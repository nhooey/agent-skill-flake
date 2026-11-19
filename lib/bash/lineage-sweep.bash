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

# sweep_report <reason> <path> — print one GC-root entry the sweep removes,
# or with $dry_run would remove, and count it in lineage_sweep's $swept.
sweep_report() {
  if [ "$dry_run" = "1" ]; then
    printf 'would %s GC root (%s): %s\n' "$sweep_verb" "$1" "$2"
  else
    printf '%s GC root (%s): %s\n' "$sweep_label" "$1" "$2"
  fi
  swept=$((swept + 1))
}

# gc_gone_target_dirs — print each target's records dir whose .target
# points at a dir that is gone, one a line, sorted.
gc_gone_target_dirs() {
  local dir link
  while IFS=$'\t' read -r dir link; do
    [ -e "$link" ] || printf '%s\n' "$dir"
  done < <(find "$gc_targets_dir" -mindepth 2 -maxdepth 2 -name "$GC_TARGET_RECORD" -type l \
    -printf '%h\t%l\n' 2>/dev/null | sort)
}

# sweep_shared_gc_roots — prune the shared layout (see scope.bash) under
# its lock:
#   - every record of a target whose .target points at a dir that is gone;
#   - this target's previous-build records whose current record is gone
#     (prune-gc-roots drops other targets');
#   - every record of a shared root whose store path is gone, and the root;
#   - every shared root no record uses any more, and any without an anchor.
# It first relinks this target's records that a copy of the GC-roots dir
# split from their anchors (gc_target_relink). It reads every target's
# .target, this target's records and the shared roots; every target's
# records only for a shared root whose store path is gone, which a root
# rarely lets happen, and for a legacy root (shared_current_store_paths).
# The lock entry goes too when a record of this target's current build
# goes with its store path. A dry run lists the records it would remove,
# and the shared roots no record uses already, not those its removals
# would leave unused.
sweep_shared_gc_roots() {
  [ -d "$gc_shared_dir" ] || return 0
  local dir rec base root anchor
  local -a gone_dirs=() recs=()
  if [ "$dry_run" != "1" ]; then
    gc_roots_lock || return 0
    # Every writer holds the lock, so anything in tmp/ is a stopped run's.
    find "$gc_shared_dir/tmp" -mindepth 1 -maxdepth 1 -delete 2>/dev/null || true
    gc_target_relink
  fi

  # Records go first; the roots they leave without a record go in the
  # last pass, which reports them.
  mapfile -t gone_dirs < <(gc_gone_target_dirs)
  for dir in "${gone_dirs[@]}"; do
    recs=("$dir"/* "$dir/$GC_TARGET_RECORD")
    [ "$dry_run" = "1" ] || rm -rf -- "$dir"
    for rec in "${recs[@]}"; do
      sweep_report 'install target gone' "$rec"
    done
  done

  for rec in "$gc_target_dir"/*"$GC_ROOT_PREVIOUS_SUFFIX"; do
    if [ ! -f "$rec" ] || [ -f "${rec%"$GC_ROOT_PREVIOUS_SUFFIX"}" ]; then
      continue
    fi
    [ "$dry_run" = "1" ] || rm -f -- "$rec"
    sweep_report 'previous build, current root gone' "$rec"
  done

  while IFS= read -r base; do
    root=$gc_store_dir/$base
    anchor=$root$GC_ANCHOR_SUFFIX
    recs=()
    if [ -f "$anchor" ]; then
      mapfile -t recs < <(find "$gc_targets_dir" -mindepth 2 -maxdepth 2 -type f \
        -samefile "$anchor" 2>/dev/null | sort)
    fi
    for rec in "${recs[@]}"; do
      if [ "$dry_run" != "1" ]; then
        rm -f -- "$rec"
        if [ "${rec%/*}" = "$gc_target_dir" ] && [ "${rec%"$GC_ROOT_PREVIOUS_SUFFIX"}" = "$rec" ]; then
          lock_remove "${rec##*/}"
        fi
      fi
      sweep_report 'target gone' "$rec"
    done
    [ "$dry_run" = "1" ] || rm -f -- "$root" "$anchor"
    sweep_report 'target gone' "$root"
  done < <(find "$gc_store_dir" -mindepth 1 -maxdepth 1 -xtype l -printf '%f\n' 2>/dev/null | sort)

  while IFS= read -r base; do
    root=$gc_store_dir/${base%"$GC_ANCHOR_SUFFIX"}
    [ "$dry_run" = "1" ] || rm -f -- "$root" "$gc_store_dir/$base"
    sweep_report 'no record left' "$root"
  done < <(find "$gc_store_dir" -mindepth 1 -maxdepth 1 -type f -name "*$GC_ANCHOR_SUFFIX" -links 1 \
    -printf '%f\n' 2>/dev/null | sort)
  while IFS= read -r base; do
    [ -f "$gc_store_dir/$base$GC_ANCHOR_SUFFIX" ] && continue
    [ "$dry_run" = "1" ] || rm -f -- "$gc_store_dir/$base"
    sweep_report 'no record left' "$gc_store_dir/$base"
  done < <(find "$gc_store_dir" -mindepth 1 -maxdepth 1 -type l -printf '%f\n' 2>/dev/null | sort)
}

# shared_current_store_paths [<name>...] — print each store path a current
# record (not a previous-build one) of a target that still exists uses,
# one a line, leaving out this target's records of each <name>, the
# entries the sweep removed or would remove. Neither those records nor a
# gone target's count: a locked run removes them, but a dry run or a run
# without the lock still finds them. Reads every record, so lineage_sweep
# calls it only when a legacy root needs it.
shared_current_store_paths() {
  [ -d "$gc_targets_dir" ] || return 0
  local -A current=() gone=() skip=()
  local dir name ino base
  for name in "$@"; do
    skip[$name]=1
  done
  while IFS= read -r dir; do
    gone[$dir]=1
  done < <(gc_gone_target_dirs)
  while IFS=$'\t' read -r dir name ino; do
    if [ -n "${gone[$dir]+x}" ] || { [ "$dir" = "$gc_target_dir" ] && [ -n "${skip[$name]+x}" ]; }; then
      continue
    fi
    current[$ino]=1
  done < <(find "$gc_targets_dir" -mindepth 2 -maxdepth 2 -type f \
    ! -name "*$GC_ROOT_PREVIOUS_SUFFIX" -printf '%h\t%f\t%i\n' 2>/dev/null)
  while IFS=$'\t' read -r ino base; do
    [ -n "${current[$ino]+x}" ] || continue
    readlink "$gc_store_dir/${base%"$GC_ANCHOR_SUFFIX"}" || true
  done < <(find "$gc_store_dir" -mindepth 1 -maxdepth 1 -type f -name "*$GC_ANCHOR_SUFFIX" \
    -printf '%i\t%f\n' 2>/dev/null)
}

lineage_sweep() {
  local entry name gc target swept=0
  local -A swept_names=()

  shopt -s nullglob
  # 1. Walk $target_root/* — remove qualifying managed entries (and, via
  #    cleanup_skill_entry, their GC root + lock entry).
  if [ -d "$target_root" ]; then
    for entry in "$target_root"/*; do
      entry_predicate "$entry" || continue
      name=$(basename "$entry")
      swept_names[$name]=1
      if [ "$dry_run" = "1" ]; then
        printf 'would %s: %s\n' "$sweep_verb" "$entry"
      else
        cleanup_skill_entry "$name"
        printf '%s: %s\n' "$sweep_label" "$entry"
      fi
      swept=$((swept + 1))
    done
  fi

  # 2. Prune the shared layout (sweep_shared_gc_roots), then walk the flat
  #    $gcroots_dir/claude-skill-* links, pruning those that protect
  #    nothing:
  #      - every root and the record of a target whose record points at a
  #        dir that is gone (a removed worktree's skills dir, say);
  #      - any root whose store-path target no longer exists in the store;
  #      - a previous-build root whose current root is gone;
  #      - a legacy shared root (claude-skill-<name>, no target tag) whose
  #        store path another, live target's current root or record also
  #        points at, other than this target's root or record of an entry
  #        pass 1 removed, or in a dry run would remove.
  #    A live legacy root no per-target root covers is kept: some target
  #    not yet re-installed may still have only that root protecting it.
  #    The lock entry goes too only when the store path is gone and the
  #    root was this target's current one.
  if [ -d "$gcroots_dir" ]; then
    sweep_shared_gc_roots
    local -A link_of=() gone_tags=() tagged_targets=()
    local -a gc_names=()
    local gc_name reason lock_sp has_legacy=0
    # One find lists every entry and its link, where a readlink per entry
    # would start tens of thousands of processes.
    while IFS=$'\t' read -r gc_name target; do
      gc_root_parse "$gc_name" || continue
      gc_names+=("$gc_name")
      link_of[$gc_name]=$target
      if [ "$gc_root_parsed_kind" = record ] && [ ! -e "$target" ]; then
        gone_tags[$gc_root_parsed_tag]=1
      elif [ "$gc_root_parsed_kind" = legacy ]; then
        has_legacy=1
      fi
    done < <(find "$gcroots_dir" -mindepth 1 -maxdepth 1 -type l -name "${GC_ROOT_PREFIX}*" -printf '%f\t%l\n' | sort)
    for gc_name in "${gc_names[@]}"; do
      gc_root_parse "$gc_name"
      # Only current roots supersede a legacy root: a previous-build root
      # moves on at the next rebuild, leaving its store path unrooted. Nor
      # do this target's roots of the entries pass 1 removed, which a dry
      # run leaves in place.
      if [ "$gc_root_parsed_kind" = root ] && [ -z "${gone_tags[$gc_root_parsed_tag]+x}" ] &&
        ! { [ "$gc_root_parsed_tag" = "$gc_root_tag" ] && [ -n "${swept_names[$gc_root_parsed_name]+x}" ]; }; then
        tagged_targets[${link_of[$gc_name]}]=1
      fi
    done
    if [ "$has_legacy" = 1 ]; then
      while IFS= read -r target; do
        tagged_targets[$target]=1
      done < <(shared_current_store_paths "${!swept_names[@]}")
    fi
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
      elif [ "$gc_root_parsed_kind" = previous ] &&
        [ -z "${link_of[${gc_name%"$GC_ROOT_PREVIOUS_SUFFIX"}]+x}" ]; then
        reason='previous build, current root gone'
      elif [ "$gc_root_parsed_kind" = legacy ] && [ -n "${tagged_targets[$target]+x}" ]; then
        reason='legacy, superseded by a per-target root'
      else
        continue
      fi
      if [ "$dry_run" != "1" ]; then
        rm -f "$gc"
        if [ "$reason" = 'target gone' ] && [ "$gc_root_parsed_kind" != previous ]; then
          if [ "$gc_root_parsed_tag" = "$gc_root_tag" ]; then
            lock_remove "$name"
          elif [ -z "$gc_root_parsed_tag" ]; then
            lock_sp=$(lock_store_path "$name")
            if [ "$lock_sp" = "$target" ]; then
              lock_remove "$name"
            fi
          fi
        fi
      fi
      sweep_report "$reason" "$gc"
    done
  fi

  if [ "$dry_run" = "1" ]; then
    printf '\n%d entr(y/ies) would be %s (managedBy=%s).\n' "$swept" "$sweep_label" "$upstream_url"
  else
    printf '\n%d entr(y/ies) %s (managedBy=%s).\n' "$swept" "$sweep_label" "$upstream_url"
  fi
}
