# Bash helpers for the aggregate lock file at
# `$target_root/.flake-skills-lock.json`. The lock is a denormalized index
# of installed skills (one entry per `$target_root/<skillName>`) drawn from
# each skill's per-install `.flake-skills-managed.json` sentinel — same
# data, indexed by name for human inspection (`cat $target_root/.flake-
# skills-lock.json`). It is descriptive, not authoritative; install and
# reconcile rebuild it from the symlinks + sentinels.
#
# Atomicity: tmp-write + `mv -f` so an interrupted writer can't leave a
# half-written file behind. No advisory lock — concurrent installs of
# the same skill name would race, but each write transitions through a
# valid state.
#
# Ownership tagging: the caller sets `owner_app` (the bare installer
# appName, emitted by mkInstaller / mkReconcile) and each entry it writes
# carries an `installedBy` field set to that appName. This lets a scoped
# reconcile sweep only the strays it owns and leave a coexisting
# aggregate's entries alone.

lock_path() { printf '%s/.flake-skills-lock.json' "$target_root"; }

lock_init_if_absent() {
  local lock
  lock=$(lock_path)
  mkdir -p "$(dirname "$lock")"
  if [ ! -f "$lock" ]; then
    printf '%s\n' '{"schemaVersion":1,"skills":{}}' >"$lock"
  fi
}

# Read the per-install sentinel for $store_path/$skill_name. Returns
# `{}` if the sentinel is missing (e.g. skill built by an older
# flake-skills rev) so callers don't need to special-case it.
lock_read_sentinel() {
  local store_path="$1" skill_name="$2"
  local sentinel="$store_path/share/claude-skills/$skill_name/.flake-skills-managed.json"
  if [ -f "$sentinel" ]; then
    cat "$sentinel"
  else
    printf '%s' '{}'
  fi
}

# lock_upsert  $skill_name  $store_path
lock_upsert() {
  local skill_name="$1" store_path="$2"
  local lock tmp now sentinel owner
  lock=$(lock_path)
  tmp="$lock.tmp.$$"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  owner="${owner_app:-}"
  sentinel=$(lock_read_sentinel "$store_path" "$skill_name")
  lock_init_if_absent
  jq \
    --arg name "$skill_name" \
    --argjson s "$sentinel" \
    --arg sp "$store_path" \
    --arg t "$now" \
    --arg owner "$owner" \
    '.skills[$name] = ($s + {storePath: $sp, installedAt: $t}
      + (if $owner == "" then {} else {installedBy: $owner} end))' \
    "$lock" >"$tmp"
  mv -f "$tmp" "$lock"
}

# lock_installed_by  $skill_name  -> prints the entry's installedBy
# (the owning appName) or empty if the lock, the entry, or the field is
# absent. Read by reconcile's scoped sweep to decide whose stray an
# undeclared entry is.
lock_installed_by() {
  local skill_name="$1" lock
  lock=$(lock_path)
  [ -f "$lock" ] || return 0
  jq -r --arg n "$skill_name" '.skills[$n].installedBy // empty' "$lock" 2>/dev/null || true
}

# lock_remove  $skill_name
lock_remove() {
  local skill_name="$1" lock tmp
  lock=$(lock_path)
  [ -f "$lock" ] || return 0
  tmp="$lock.tmp.$$"
  jq --arg name "$skill_name" 'del(.skills[$name])' "$lock" >"$tmp"
  mv -f "$tmp" "$lock"
}

# remove_skill_links  $skill_name
# Remove a skill's user-facing symlink (<target_root>/<name>) and per-user
# GC root (<gcroots_dir>/claude-skill-<name>). Leaves the lock untouched —
# reconcile owns the lock and rebuilds it wholesale, so its sweep removes
# only the links and defers the lock to lock_replace_all.
remove_skill_links() {
  local skill_name="$1"
  rm -f "$target_root/$skill_name"
  rm -f "$gcroots_dir/claude-skill-$skill_name"
}

# cleanup_skill_entry  $skill_name
# Full inverse of an install: drop the symlink, the GC root, and the lock
# entry. Used by uninstall and by reap's broken-target pass.
cleanup_skill_entry() {
  local skill_name="$1"
  remove_skill_links "$skill_name"
  lock_remove "$skill_name"
}

# lock_replace_all  "$@"  -- each arg is "name:store_path"
# Rebuild .skills from the args (used by reconcile). The rebuild is
# scoped to `owner_app`: entries owned by *other* appNames (installedBy
# set and != ours) are carried over untouched, so a scoped reconcile
# rewrites only its own slice and never drops a coexisting aggregate's
# entries. Entries with no recorded owner are dropped.
lock_replace_all() {
  local lock tmp now new_skills sentinel skill_name store_path entry owner
  lock=$(lock_path)
  tmp="$lock.tmp.$$"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  owner="${owner_app:-}"
  lock_init_if_absent
  if [ -n "$owner" ]; then
    new_skills=$(jq --arg owner "$owner" \
      '.skills | with_entries(select((.value.installedBy // "") != ""
        and (.value.installedBy // "") != $owner))' \
      "$lock")
  else
    new_skills='{}'
  fi
  for entry in "$@"; do
    skill_name=${entry%%:*}
    store_path=${entry#*:}
    sentinel=$(lock_read_sentinel "$store_path" "$skill_name")
    new_skills=$(jq -n \
      --argjson cur "$new_skills" \
      --arg name "$skill_name" \
      --argjson s "$sentinel" \
      --arg sp "$store_path" \
      --arg t "$now" \
      --arg owner "$owner" \
      '$cur + {($name): ($s + {storePath: $sp, installedAt: $t}
        + (if $owner == "" then {} else {installedBy: $owner} end))}')
  done
  jq --argjson new "$new_skills" '.skills = $new' "$lock" >"$tmp"
  mv -f "$tmp" "$lock"
}
