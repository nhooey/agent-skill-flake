# Shared bash helpers used by reap, reconcile, and uninstall to identify
# which `$target_root` entries are "ours" (built by this agent-skill-flake
# lineage). The check is layered:
#   1. If the symlink target is live, read `.agent-skill-flake-managed.json` and
#      verify `managedBy == upstream_url`. This is the strict signal.
#   2. If the symlink target is broken (store path GC'd), fall back to
#      checking for a GC root for <name>: the entry's own directory's
#      per-target root (`claude-skill-<tag>-<name>`, see gc_root_path), or
#      the legacy shared `claude-skill-<name>`. This is a naming-convention
#      signal — single-lineage assumption: a user with forks of
#      agent-skill-flake could see false-positives across lineages.

# is_ours_live  $entry  $upstream_url
# Returns 0 if the symlink is alive AND its sentinel matches upstream_url.
is_ours_live() {
  local entry="$1" upstream="$2" sentinel managed_by
  [ -L "$entry" ] || return 1
  [ -e "$entry" ] || return 1
  sentinel="${entry}/${SENTINEL_FILE}"
  [ -f "$sentinel" ] || return 1
  managed_by=$(jq -r '.managedBy // empty' "$sentinel" 2>/dev/null) || return 1
  [ "$managed_by" = "$upstream" ]
}

# is_ours_broken  $entry  $gcroots_dir
# Returns 0 if the symlink target is missing AND a GC root for it exists
# (the naming-convention fallback). Best-effort.
is_ours_broken() {
  local entry="$1" gcroots_dir="$2" name root
  [ -L "$entry" ] || return 1
  [ -e "$entry" ] && return 1
  name=$(basename "$entry")
  for root in \
    "$(gc_root_path "$name" "$(gc_root_tag_for "$(dirname "$entry")")")" \
    "$(legacy_gc_root_path "$name")"; do
    if [ -L "$root" ] || [ -e "$root" ]; then
      return 0
    fi
  done
  return 1
}
