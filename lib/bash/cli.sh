# cli.sh — the `agent-skill-flake` command: `apply` and `sync-project`.
#
# Injected by the Nix wrapper (lib/internal.nix mkCli), before this file:
#   scopePrelude       app_name, personal_suffix, project_suffix, scope.bash
#   owner_app          the reconcile owner of the skills sync-project installs
#   upstream_url       this lineage's managedBy URL
#   project_link       the profile's project-scope link (.claude/skills)
#   reconcile_script   store path of reconcile.sh, sourced by sync-project
# and the sourced modules config.bash, apply.bash, ownership.bash,
# lock.bash and project-layout.bash.

cli_usage() {
  cat <<EOF
Usage: agent-skill-flake <command> [options]

Commands:
  apply          Apply the user-global config: write each agent's settings
                 (claude-code: trusted-dirs into permissions.additionalDirectories
                 of ~/.claude/settings.json) and register the git config hook
                 that runs \`sync-project --from-hook\` after a checkout.
  sync-project   Install the current repo's configured skills into
                 <repo-root>/$project_suffix and remove the ones it installed
                 that are no longer configured.
  help           Show this help and exit.

sync-project options:
  --from-hook           Run as git's post-checkout hook: act only on a branch
                        checkout (including clone and worktree add), print at
                        most two lines, and always exit 0.
  --gcroots-dir=<path>  Override the per-user GC-roots dir
                        (default: /nix/var/nix/gcroots/per-user/\$USER).

Files:
  $(global_config_file)
      user-global: [defaults], [repo."<host>/<owner>/<name>"], [agents.<agent>]
  <repo-root>/$LOCAL_CONFIG_RELPATH
      in-checkout override of the repo's table; never committed

Precedence: the local file > the user-global repo entry > [defaults]. The
local file replaces the repo entry unless it has a \`merge\` table; see the
README's "User config" section.
EOF
}

cmd_apply() {
  local arg file global rc=0
  for arg in "$@"; do
    case "$arg" in
    -h | --help)
      cli_usage
      return 0
      ;;
    *)
      printf 'agent-skill-flake apply: unexpected argument: %s\n' "$arg" >&2
      return 2
      ;;
    esac
  done

  file=$(global_config_file)
  if [ -f "$file" ]; then
    global=$(read_toml "$file") || {
      printf 'agent-skill-flake: could not read %s\n' "$file" >&2
      return 1
    }
  else
    printf 'agent-skill-flake: no config at %s; no agent settings to write\n' "$file"
    global='{}'
  fi

  apply_agents "$global" || rc=1
  register_git_hook || rc=1
  return "$rc"
}

# skills_in_output <store-path> — the skill names a built output provides:
# each <out>/share/claude-skills/<name>/ holding a SKILL.md.
skills_in_output() {
  local out=$1 dir
  for dir in "$out/$SKILLS_SHARE_SUBDIR"/*/; do
    [ -f "$dir/SKILL.md" ] && basename "$dir"
  done
  return 0
}

# build_installable <installable> <repo-root> — print the store path(s) of
# a skills entry. A /nix/store path is used as it is; anything else is a
# flake installable, built with `nix build` from the repo root (so a
# relative `path:./…` ref resolves against the repo).
build_installable() {
  local inst=$1 root=$2
  case "$inst" in
  /nix/store/*)
    if [ ! -e "$inst" ]; then
      printf 'agent-skill-flake: %s does not exist\n' "$inst" >&2
      return 1
    fi
    printf '%s\n' "$inst"
    ;;
  *)
    if ! command -v nix >/dev/null 2>&1; then
      printf 'agent-skill-flake: nix is not on PATH; it is needed to build %s\n' "$inst" >&2
      return 1
    fi
    (cd "$root" && nix --extra-experimental-features 'nix-command flakes' \
      build --no-link --print-out-paths "$inst") || {
      printf 'agent-skill-flake: could not build %s\n' "$inst" >&2
      return 1
    }
    ;;
  esac
}

# sync_project_run [--gcroots-dir=<path>] — the work behind sync-project.
sync_project_run() {
  local root origin key gfile lfile global local_json resolved origin_kind source_label
  local inst out name outs names count
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  root=$(git rev-parse --show-toplevel)
  origin=$(git -C "$root" remote get-url origin 2>/dev/null) || return 0
  [ -n "$origin" ] || return 0
  key=$(normalize_origin "$origin")

  gfile=$(global_config_file)
  lfile=$(local_config_file "$root")
  [ -f "$gfile" ] || [ -f "$lfile" ] || return 0
  global=$(read_toml_if_present "$gfile") || {
    printf 'agent-skill-flake: could not read %s\n' "$gfile" >&2
    return 1
  }
  local_json=$(read_toml_if_present "$lfile") || {
    printf 'agent-skill-flake: could not read %s\n' "$lfile" >&2
    return 1
  }
  resolved=$(resolve_repo_config "$global" "$local_json" "$key") || return 1
  [ "$(jq -r .found <<<"$resolved")" = "true" ] || return 0

  if [ -d "$root/skills-devshell" ]; then
    printf 'agent-skill-flake: skipped %s: its skills-devshell/ owns project skills\n' "$root"
    return 0
  fi

  origin_kind=$(jq -r '.skillsOrigin // empty' <<<"$resolved")
  case "$origin_kind" in
  local) source_label="local: $LOCAL_CONFIG_RELPATH" ;;
  user-global) source_label="user-global: $gfile [repo.\"$key\"]" ;;
  "user-global defaults") source_label="user-global: $gfile [defaults]" ;;
  *)
    printf 'agent-skill-flake: no skills configured for %s; nothing to do\n' "$key"
    return 0
    ;;
  esac

  declare -a skills_list=()
  declare -A provider=()
  while IFS= read -r inst; do
    outs=$(build_installable "$inst" "$root") || return 1
    count=0
    while IFS= read -r out; do
      [ -n "$out" ] || continue
      names=$(skills_in_output "$out")
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ -n "${provider[$name]+x}" ]; then
          printf 'agent-skill-flake: skill %s is provided by both %s and %s\n' \
            "$name" "${provider[$name]}" "$inst" >&2
          return 1
        fi
        provider[$name]=$inst
        skills_list+=("$name:$out")
        printf 'skill %s <- %s (%s)\n' "$name" "$inst" "$source_label"
        count=$((count + 1))
      done <<<"$names"
    done <<<"$outs"
    if [ "$count" = 0 ]; then
      printf 'agent-skill-flake: %s provides no skills (no share/claude-skills/<name>/SKILL.md)\n' "$inst" >&2
      return 1
    fi
  done < <(jq -r '.effective.skills[]' <<<"$resolved")

  cd "$root"
  # shellcheck disable=SC1090 # reconcile_script is a store path set by the wrapper
  source "$reconcile_script" --scope=project "$@"
  printf 'agent-skill-flake: %d project skill(s) in sync in %s/%s (%s)\n' \
    "${#skills_list[@]}" "$root" "$project_suffix" "$source_label"
}

cmd_sync_project() {
  local arg from_hook=0 out last rc
  local -a pass=() positional=()
  for arg in "$@"; do
    case "$arg" in
    -h | --help)
      cli_usage
      return 0
      ;;
    --from-hook) from_hook=1 ;;
    --gcroots-dir=*) pass+=("$arg") ;;
    *) positional+=("$arg") ;;
    esac
  done

  if [ "$from_hook" = 0 ]; then
    if [ ${#positional[@]} -gt 0 ]; then
      printf 'agent-skill-flake sync-project: unexpected argument: %s\n' "${positional[0]}" >&2
      return 2
    fi
    sync_project_run "${pass[@]}"
    return
  fi

  # post-checkout passes <old-head> <new-head> <flag>; flag 1 is a branch
  # checkout (clone and `git worktree add` included), 0 a file checkout.
  [ "${positional[2]:-}" = "1" ] || return 0
  # A separate process, so errexit applies to the work while this side
  # turns any failure into a short note and exit 0.
  if out=$("$0" sync-project "${pass[@]}" 2>&1); then
    last=$(grep -v '^[[:space:]]*$' <<<"$out" | tail -n 1 || true)
    [ -z "$last" ] || printf '%s\n' "$last"
  else
    rc=$?
    last=$(grep -v '^[[:space:]]*$' <<<"$out" | tail -n 1 || true)
    printf 'agent-skill-flake: sync-project failed (exit %d): %s\n' "$rc" "${last:-no output}"
    printf '  Run `agent-skill-flake sync-project` in %s for details.\n' "$PWD"
  fi
  return 0
}

case "${1:-}" in
apply)
  shift
  cmd_apply "$@"
  ;;
sync-project)
  shift
  # Never fail a git command: a hook run exits 0 whatever happens.
  case " $* " in
  *" --from-hook "*) cmd_sync_project "$@" || true ;;
  *) cmd_sync_project "$@" ;;
  esac
  ;;
help | -h | --help)
  cli_usage
  ;;
"")
  cli_usage >&2
  exit 2
  ;;
*)
  printf 'agent-skill-flake: unknown command: %s\n' "$1" >&2
  printf '  See `agent-skill-flake --help` for usage.\n' >&2
  exit 2
  ;;
esac
