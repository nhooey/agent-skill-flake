mkdir -p "$target_root"
gcroots_ok=1
if ! mkdir -p "$gcroots_dir" 2>/dev/null; then
  gcroots_ok=0
  printf 'WARNING: could not create %s; store paths may be GC-eligible\n' "$gcroots_dir" >&2
fi

# 1. Install / refresh each declared skill (idempotent).
declare -a keep_names=()
for entry in "${skills_list[@]}"; do
  skill_name=${entry%%:*}
  store_path=${entry#*:}
  skill_subpath="$store_path/share/claude-skills/$skill_name"
  target="$target_root/$skill_name"
  rm -rf "$target"
  ln -sfn "$skill_subpath" "$target"
  printf 'reconciled (install): %s -> %s\n' "$target" "$skill_subpath"
  if [ "$gcroots_ok" = "1" ]; then
    ln -sfn "$store_path" "$gcroots_dir/claude-skill-$skill_name" || \
      printf 'WARNING: could not write GC root for %s\n' "$skill_name" >&2
  fi
  keep_names+=("$skill_name")
done

# 2. Sweep $target_root for managed entries NOT in the declared set.
swept=0
if [ -d "$target_root" ]; then
  shopt -s nullglob
  for entry in "$target_root"/*; do
    name=$(basename "$entry")
    in_keep=0
    for k in "${keep_names[@]}"; do
      if [ "$k" = "$name" ]; then
        in_keep=1
        break
      fi
    done
    [ "$in_keep" = "1" ] && continue

    if is_ours_live "$entry" "$upstream_url"; then
      rm -f "$entry"
      rm -f "$gcroots_dir/claude-skill-$name"
      printf 'reconciled (sweep): %s\n' "$entry"
      swept=$((swept + 1))
    elif is_ours_broken "$entry" "$gcroots_dir"; then
      rm -f "$entry"
      rm -f "$gcroots_dir/claude-skill-$name"
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
  "${#keep_names[@]}" "$swept"
