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
#   3. If the symlink target is broken and no GC root names it, accept a
#      lock entry written before installs recorded `managedBy`: the
#      directory's lock lists <name> with no `managedBy`, and the link
#      points into that entry's `storePath`, a missing
#      `/nix/store/*-claude-skill-*` path.

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
# (the naming-convention fallback), or the lock holds a pre-`managedBy`
# entry for it (is_ours_broken_by_lock). Best-effort.
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
  is_ours_broken_by_lock "$entry"
}

# is_ours_broken_by_lock  $entry
# Returns 0 if the lock in the entry's directory lists it with no
# `managedBy` and a `storePath` that is a missing claude-skill store
# path, and the link points into that store path.
is_ours_broken_by_lock() {
  local entry="$1" lock name store_path target
  lock="$(dirname "$entry")/.agent-skill-flake-lock.json"
  [ -f "$lock" ] || return 1
  name=$(basename "$entry")
  store_path=$(jq -r --arg n "$name" '
    .skills[$n] // empty
    | select((.managedBy // "") == "")
    | .storePath // empty' "$lock" 2>/dev/null) || return 1
  case "$store_path" in
  /nix/store/*-claude-skill-*) ;;
  *) return 1 ;;
  esac
  [ -e "$store_path" ] && return 1
  target=$(readlink "$entry")
  case "$target" in
  "$store_path" | "$store_path"/*) return 0 ;;
  esac
  return 1
}
