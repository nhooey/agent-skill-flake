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

lock_path() { printf '%s/.flake-skills-lock.json' "$target_root"; }

lock_init_if_absent() {
  local lock; lock=$(lock_path)
  mkdir -p "$(dirname "$lock")"
  if [ ! -f "$lock" ]; then
    printf '%s\n' '{"schemaVersion":1,"skills":{}}' > "$lock"
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
  local lock tmp now sentinel
  lock=$(lock_path)
  tmp="$lock.tmp.$$"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  sentinel=$(lock_read_sentinel "$store_path" "$skill_name")
  lock_init_if_absent
  jq \
    --arg name "$skill_name" \
    --argjson s "$sentinel" \
    --arg sp "$store_path" \
    --arg t "$now" \
    '.skills[$name] = ($s + {storePath: $sp, installedAt: $t})' \
    "$lock" > "$tmp"
  mv -f "$tmp" "$lock"
}

# lock_remove  $skill_name
lock_remove() {
  local skill_name="$1" lock tmp
  lock=$(lock_path)
  [ -f "$lock" ] || return 0
  tmp="$lock.tmp.$$"
  jq --arg name "$skill_name" 'del(.skills[$name])' "$lock" > "$tmp"
  mv -f "$tmp" "$lock"
}

# lock_replace_all  "$@"  -- each arg is "name:store_path"
# Rebuild .skills entirely from the args (used by reconcile).
lock_replace_all() {
  local lock tmp now new_skills sentinel skill_name store_path entry
  lock=$(lock_path)
  tmp="$lock.tmp.$$"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  lock_init_if_absent
  new_skills='{}'
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
      '$cur + {($name): ($s + {storePath: $sp, installedAt: $t})}')
  done
  jq --argjson new "$new_skills" '.skills = $new' "$lock" > "$tmp"
  mv -f "$tmp" "$lock"
}
