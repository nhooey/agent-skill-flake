reaped=0

# 1. Walk $target_root/* — remove our managed entries whose symlink
#    target is gone. Live entries are kept (reconcile handles those).
if [ -d "$target_root" ]; then
  shopt -s nullglob
  for entry in "$target_root"/*; do
    if is_ours_broken "$entry" "$gcroots_dir"; then
      name=$(basename "$entry")
      rm -f "$entry"
      rm -f "$gcroots_dir/claude-skill-$name"
      lock_remove "$name"
      printf 'reaped (broken target): %s\n' "$entry"
      reaped=$((reaped + 1))
    fi
  done
fi

# 2. Walk $gcroots_dir/claude-skill-* — remove orphan GC roots whose
#    store-path target no longer exists in the store.
if [ -d "$gcroots_dir" ]; then
  shopt -s nullglob
  for gc in "$gcroots_dir"/claude-skill-*; do
    [ -L "$gc" ] || continue
    target=$(readlink "$gc")
    if [ ! -e "$target" ]; then
      name=${gc##*/claude-skill-}
      rm -f "$gc"
      lock_remove "$name"
      printf 'reaped GC root (target gone): %s\n' "$gc"
      reaped=$((reaped + 1))
    fi
  done
fi

printf '\n%d entr(y/ies) reaped (managedBy=%s).\n' "$reaped" "$upstream_url"
