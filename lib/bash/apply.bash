# apply.bash — the writers behind `agent-skill-flake apply`.
#
# `apply` reads the user-global config (config.bash) and brings user-level
# files in line with it: each agent's settings, through the writer for that
# agent, and the git config hook that runs `sync-project` after a checkout.
#
# Every writer changes one thing and leaves the rest of its file alone, is
# idempotent (no write when the file already says what it should), and
# refuses to touch a file it doesn't own: one that resolves into /nix/store
# or isn't writable, as with a Home Manager-managed file. A refusing writer
# prints what to add by hand and returns 1; it changes nothing.
#
# Adding an agent: write `agent_writer_<agent>` (dashes become underscores)
# taking the agent's config table as JSON, and add the agent's name to
# AGENT_WRITERS.

AGENT_WRITERS=(claude-code)

GIT_HOOK_NAME="agent-skill-flake-sync"
GIT_HOOK_EVENT="post-checkout"
GIT_HOOK_COMMAND="agent-skill-flake sync-project --from-hook"

# write_refusal <file> — print why <file> must not be written (it resolves
# into /nix/store, or it or the directory it would be created in isn't
# writable), or nothing if it can be.
write_refusal() {
  local file=$1 resolved dir
  resolved=$(readlink -f "$file" 2>/dev/null || printf '%s' "$file")
  case "$resolved" in
  /nix/store/*)
    printf '%s resolves into the Nix store (%s), so it is managed by Nix, e.g. Home Manager' "$file" "$resolved"
    return 0
    ;;
  esac
  if [ -e "$resolved" ]; then
    [ -w "$resolved" ] || printf '%s is not writable' "$file"
    return 0
  fi
  dir=$(dirname "$resolved")
  while [ ! -e "$dir" ]; do
    dir=$(dirname "$dir")
  done
  [ -w "$dir" ] || printf '%s cannot be created: %s is not writable' "$file" "$dir"
}

# write_json_file <file> <json> — write <json> to <file> atomically,
# through a symlink to its target rather than replacing the link.
write_json_file() {
  local file=$1 json=$2 resolved tmp
  resolved=$(readlink -f "$file" 2>/dev/null || printf '%s' "$file")
  mkdir -p "$(dirname "$resolved")"
  tmp="$resolved.tmp.$$"
  printf '%s\n' "$json" >"$tmp"
  [ -e "$resolved" ] && chmod --reference="$resolved" "$tmp"
  mv -f "$tmp" "$resolved"
}

# expand_home_dirs <json-array> — the array with a leading `~` expanded to
# $HOME in each entry.
expand_home_dirs() {
  jq -c --arg home "$HOME" \
    'map(if . == "~" then $home elif startswith("~/") then $home + .[1:] else . end)' <<<"$1"
}

# agent_writer_claude_code <agent-json>
# `trusted-dirs = [...]` → `permissions.additionalDirectories` in
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json. Directories already
# listed there are kept; the configured ones are added after them, once.
agent_writer_claude_code() {
  local agent=$1 settings dirs current updated reason
  settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  dirs=$(jq -c '."trusted-dirs" // []' <<<"$agent")
  if ! jq -e 'type == "array" and all(type == "string")' >/dev/null <<<"$dirs"; then
    printf 'claude-code: trusted-dirs must be a list of directory paths\n' >&2
    return 1
  fi
  dirs=$(expand_home_dirs "$dirs")
  if [ "$dirs" = "[]" ]; then
    printf 'claude-code: no trusted-dirs configured; %s left alone\n' "$settings"
    return 0
  fi

  current='{}'
  if [ -e "$settings" ]; then
    if ! current=$(jq -c . "$settings" 2>/dev/null) || [ -z "$current" ]; then
      printf 'claude-code: %s is not valid JSON; fix it and re-run. Nothing was changed.\n' "$settings" >&2
      return 1
    fi
  fi
  updated=$(jq --argjson dirs "$dirs" '
    .permissions = ((.permissions // {})
      | .additionalDirectories = ((.additionalDirectories // [])
          | . + ($dirs - .) | reduce .[] as $d ([]; if index([$d]) then . else . + [$d] end)))
    ' <<<"$current")
  if [ "$(jq -c . <<<"$updated")" = "$current" ]; then
    printf 'claude-code: %s already lists every trusted dir\n' "$settings"
    return 0
  fi

  reason=$(write_refusal "$settings")
  if [ -n "$reason" ]; then
    printf 'claude-code: not writing %s: %s.\n' "$settings" "$reason" >&2
    printf '  Nothing was changed. Add this to it where it is managed:\n' >&2
    jq -n --argjson dirs "$dirs" '{permissions: {additionalDirectories: $dirs}}' | sed 's/^/    /' >&2
    return 1
  fi
  write_json_file "$settings" "$updated"
  printf 'claude-code: trusted dirs written to permissions.additionalDirectories in %s\n' "$settings"
}

# apply_agents <global-json> — run the writer for each [agents.<agent>]
# table. Returns 1 if any writer refused or failed.
apply_agents() {
  local global=$1 agent fn rc=0 known
  while IFS= read -r agent; do
    [ -n "$agent" ] || continue
    known=0
    for fn in "${AGENT_WRITERS[@]}"; do
      [ "$fn" = "$agent" ] && known=1
    done
    if [ "$known" = 0 ]; then
      printf '%s: skipped; no writer for this agent yet (known: %s)\n' "$agent" "${AGENT_WRITERS[*]}" >&2
      continue
    fi
    fn="agent_writer_${agent//-/_}"
    "$fn" "$(jq -c --arg a "$agent" '.agents[$a]' <<<"$global")" || rc=1
  done < <(jq -r '(.agents // {}) | keys[]' <<<"$global")
  return "$rc"
}

# The file `git config --global` writes: $GIT_CONFIG_GLOBAL, else
# ~/.gitconfig, else $XDG_CONFIG_HOME/git/config when only that exists.
git_global_config_file() {
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}/git/config"
  if [ -n "${GIT_CONFIG_GLOBAL:-}" ]; then
    printf '%s' "$GIT_CONFIG_GLOBAL"
  elif [ ! -e "$HOME/.gitconfig" ] && [ -e "$xdg" ]; then
    printf '%s' "$xdg"
  else
    printf '%s' "$HOME/.gitconfig"
  fi
}

print_git_hook_config() {
  printf '    [hook "%s"]\n' "$GIT_HOOK_NAME"
  printf '      event = %s\n' "$GIT_HOOK_EVENT"
  printf '      command = %s\n' "$GIT_HOOK_COMMAND"
}

# register_git_hook — set hook.agent-skill-flake-sync.{event,command} in the
# user's global git config, so `sync-project --from-hook` runs after every
# checkout, clone and `git worktree add`. A config hook runs before the
# repo's own hook and doesn't replace it.
register_git_hook() {
  local file events cmd reason
  file=$(git_global_config_file)
  events=$(git config --global --get-all "hook.$GIT_HOOK_NAME.event" 2>/dev/null || true)
  cmd=$(git config --global --get "hook.$GIT_HOOK_NAME.command" 2>/dev/null || true)
  if [ "$events" = "$GIT_HOOK_EVENT" ] && [ "$cmd" = "$GIT_HOOK_COMMAND" ]; then
    printf 'git: the %s hook is already registered in %s\n' "$GIT_HOOK_NAME" "$file"
    return 0
  fi

  reason=$(write_refusal "$file")
  if [ -z "$reason" ] &&
    git config --global --replace-all "hook.$GIT_HOOK_NAME.event" "$GIT_HOOK_EVENT" &&
    git config --global --replace-all "hook.$GIT_HOOK_NAME.command" "$GIT_HOOK_COMMAND"; then
    printf 'git: registered the %s hook (%s) in %s\n' "$GIT_HOOK_NAME" "$GIT_HOOK_EVENT" "$file"
    return 0
  fi
  printf 'git: not writing %s: %s.\n' "$file" "${reason:-git config failed}" >&2
  printf '  Add these lines to your global git config where it is managed:\n' >&2
  print_git_hook_config >&2
  return 1
}
