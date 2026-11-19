# personal-scope.bash — a project reconcile defers to the personal scope's
# copy of a skill when it holds the same version.
#
# An agent reads the skills in the personal directory as well as the
# project's, and Claude Code uses the personal copy when both hold a skill
# of the same name. So a --scope=project reconcile compares each declared
# skill with the personal directory's copy of that name, on every run and
# from the filesystem, never from what an earlier run recorded:
#   - the same version: the project's copy is not installed. A link an
#     earlier run made is removed with its GC root, so it drops out of the
#     lock's `skills` and the exclude block, and the lock records the skill
#     under `satisfiedByPersonalScope`.
#   - a different version: the project's copy is installed too, and one
#     line on stderr names both versions, the copy the agent uses, and the
#     command that updates each side. With --strict the line is an error
#     and the reconcile exits 1 once it has converged.
#   - no copy of that name there, no personal directory, a personal entry
#     whose links pass through the project's own skills directory, or a copy
#     that can't be read (reported in one line): the skill installs as it
#     does at any other scope.
#
# Two copies are the same version when their content hashes match (see
# content-hash.bash). When both are in the Nix store and their sentinels
# record a `contentHash` of the same scheme, taken at build time before
# nixpkgs-specific store paths reach the scripts, those are compared;
# otherwise both folders are hashed as they stand.
#
# Settings:
#   --ignore-personal-scope    turn the check off
#   --strict                   fail on a different version
#   AGENT_SKILL_FLAKE_PERSONAL_DIR
#                              the personal directory; default
#                              $HOME/<personal_suffix>, the one the agent reads
#   AGENT_SKILL_FLAKE_PERSONAL_UPDATE_COMMAND
#                              the command that updates the personal skills
#   AGENT_SKILL_FLAKE_PROJECT_UPDATE_COMMAND
#                              the command that updates the project's skills;
#                              default $default_project_update_command, set by
#                              the builder, else
#                              `nix flake update --flake <project-root>`
#
# Caller contract: scope.bash parsed (install_scope, project_root,
# target_root, personal_suffix, SENTINEL_FILE); lock.bash and
# content-hash.bash sourced; agent_display_name and
# personal_takes_precedence set by the wrapper.

# Help-text paragraph for reconcile. Prints to stdout.
print_personal_scope_usage() {
  cat <<EOF
Personal scope (--scope=project only):
  A declared skill whose copy in the personal directory
  (\$AGENT_SKILL_FLAKE_PERSONAL_DIR, default \$HOME/$personal_suffix) is the
  same version is left to that copy and recorded in the lock as
  satisfiedByPersonalScope; one that is a different version is installed
  too, with a warning naming both versions.
  --strict                      Exit 1 when a declared skill differs from
                                the personal scope's copy.
  --ignore-personal-scope       Don't compare with the personal scope.
  Both are rejected at another scope, and together.

EOF
}

# parse_personal_scope_args "$@" — take --strict and --ignore-personal-scope
# out of the argv, setting personal_check (warn | strict | off) and
# personal_scope_flags[] (the flags given). The rest go to the global
# personal_scope_remaining_args[], in order.
parse_personal_scope_args() {
  personal_check=warn
  personal_scope_flags=()
  personal_scope_remaining_args=()
  local arg
  for arg in "$@"; do
    case "$arg" in
    --strict)
      personal_check=strict
      personal_scope_flags+=("$arg")
      ;;
    --ignore-personal-scope)
      personal_check=off
      personal_scope_flags+=("$arg")
      ;;
    *) personal_scope_remaining_args+=("$arg") ;;
    esac
  done
}

# validate_personal_scope_args — after scope parsing, refuse the two flags
# together, or at a scope other than project, as --root is refused at a
# scope other than custom. Returns 2 after a usage error.
validate_personal_scope_args() {
  [ ${#personal_scope_flags[@]} -gt 0 ] || return 0
  local -A seen=()
  local flag
  for flag in "${personal_scope_flags[@]}"; do
    seen["$flag"]=1
  done
  if [ ${#seen[@]} -gt 1 ]; then
    usage_error '--strict and --ignore-personal-scope contradict each other'
    return 2
  fi
  if [ "$install_scope" != project ]; then
    usage_error "${personal_scope_flags[0]} is only valid with --scope=project (got --scope=$install_scope)"
    return 2
  fi
}

# personal_scope_init — find the personal directory for this run, or leave
# personal_dir empty when there is nothing to compare with: another scope,
# the check turned off, no such directory, or a project whose skill
# directory is the personal one.
personal_scope_init() {
  personal_dir=""
  personal_deferred=()
  personal_mismatches=0
  [ "$install_scope" = project ] || return 0
  [ "$personal_check" != off ] || return 0
  local dir=${AGENT_SKILL_FLAKE_PERSONAL_DIR:-}
  if [ -z "$dir" ]; then
    [ -n "${HOME:-}" ] || return 0
    dir="$HOME/$personal_suffix"
  fi
  [ -d "$dir" ] || return 0
  [ "$(realpath -- "$dir")" != "$(realpath -m -- "$target_root")" ] || return 0
  personal_dir=$dir
}

# links_through_target <path> — 0 if <path>, or any link on the way from it
# to what it names, lies in $target_root: a personal entry that is the
# project's own copy under another name, which would vanish when the
# project's copy is left out.
links_through_target() {
  local path=$1 target dir dest hops=0
  target=$(realpath -m -- "$target_root")
  while :; do
    dir=$(cd -P -- "$(dirname -- "$path")" 2>/dev/null && pwd) || return 1
    [ "$dir" != "$target" ] || return 0
    [ -L "$path" ] && [ "$hops" -lt 40 ] || return 1
    dest=$(readlink -- "$path")
    case "$dest" in
    /*) path=$dest ;;
    *) path="$dir/$dest" ;;
    esac
    hops=$((hops + 1))
  done
}

# recorded_content_hash <dir> -> the `contentHash` <dir>'s sentinel records,
# when <dir> lies in the Nix store, where nothing can have changed it since
# it was built; else nothing.
recorded_content_hash() {
  local resolved
  resolved=$(realpath -- "$1" 2>/dev/null) || return 0
  case "$resolved" in
  "${NIX_STORE_DIR:-/nix/store}"/*) ;;
  *) return 0 ;;
  esac
  [ -f "$resolved/$SENTINEL_FILE" ] || return 0
  jq -r '.contentHash // empty' "$resolved/$SENTINEL_FILE" 2>/dev/null || true
}

# personal_scope_compare <name> <project-copy> — compare a declared skill
# with the personal scope's copy of it. Sets personal_verdict (absent,
# same or different), and for a copy that is there personal_copy,
# personal_version and project_version. A copy that can't be read is
# reported in one line and counts as absent.
personal_scope_compare() {
  local name=$1 project_copy=$2
  personal_verdict=absent
  [ -n "$personal_dir" ] || return 0
  personal_copy="$personal_dir/$name"
  [ -f "$personal_copy/SKILL.md" ] || return 0
  ! links_through_target "$personal_copy" || return 0

  project_version=$(recorded_content_hash "$project_copy")
  personal_version=$(recorded_content_hash "$personal_copy")
  if [ -z "$project_version" ] || [ -z "$personal_version" ] ||
    [ "$(content_hash_scheme "$project_version")" != "$(content_hash_scheme "$personal_version")" ]; then
    if ! project_version=$(skill_content_hash "$project_copy" 2>/dev/null) ||
      ! personal_version=$(skill_content_hash "$personal_copy" 2>/dev/null); then
      printf 'WARNING: %s could not be read to compare it with this project'"'"'s %s; installing the project'"'"'s copy.\n' \
        "$personal_copy" "$name" >&2
      return 0
    fi
  fi
  if [ "$project_version" = "$personal_version" ]; then
    personal_verdict=same
  else
    personal_verdict=different
  fi
}

# personal_scope_defer <name> — leave a declared skill to the personal
# scope's copy: unless the lock gives the name to another appName, remove
# the link an earlier run made here and this target's GC root, and note
# the skill for the lock.
personal_scope_defer() {
  local name=$1 link="$target_root/$1" owner had_link=0
  owner=$(lock_installed_by "$name")
  if [ -z "$owner" ] || [ "$owner" = "${owner_app:-}" ]; then
    [ ! -L "$link" ] || had_link=1
    remove_skill_links "$name"
    if [ "$had_link" = 1 ]; then
      printf 'reconciled (left to the personal scope'"'"'s copy, %s): %s\n' "$personal_copy" "$link"
    fi
  fi
  personal_deferred+=("$name" "$personal_copy" "$personal_version")
}

# short_version <hash> -> `sha256:` and the hash's first 12 hex digits.
short_version() {
  local hex=${1##*:}
  printf 'sha256:%s' "${hex:0:12}"
}

# personal_scope_report_difference <name> — the one stderr line for a
# declared skill whose personal copy is a different version.
personal_scope_report_difference() {
  local name=$1 level=WARNING uses personal_update project_update
  [ "$personal_check" != strict ] || level=ERROR
  if [ -n "${personal_takes_precedence:-}" ]; then
    uses="$agent_display_name uses the personal copy."
  else
    uses="$agent_display_name may load either copy."
  fi
  if [ -n "${AGENT_SKILL_FLAKE_PERSONAL_UPDATE_COMMAND:-}" ]; then
    personal_update="run \`$AGENT_SKILL_FLAKE_PERSONAL_UPDATE_COMMAND\`"
  else
    personal_update="update the flake that installs $personal_dir and rebuild it (set AGENT_SKILL_FLAKE_PERSONAL_UPDATE_COMMAND to name that command)"
  fi
  project_update=${AGENT_SKILL_FLAKE_PROJECT_UPDATE_COMMAND:-${default_project_update_command:-nix flake update --flake $(printf '%q' "$project_root")}}
  printf '%s: %s is %s in the personal scope (%s) and %s in this project; both are installed. %s To update both to the latest: for the personal copy, %s; for the project'"'"'s, run `%s`.\n' \
    "$level" "$name" "$(short_version "$personal_version")" "$personal_copy" \
    "$(short_version "$project_version")" "$uses" "$personal_update" "$project_update" >&2
  personal_mismatches=$((personal_mismatches + 1))
}

# personal_scope_finish — record the deferred skills in the lock, report
# how many there were, and with --strict exit 1 if any skill differed.
personal_scope_finish() {
  lock_replace_personal_scope "${personal_deferred[@]}"
  if [ ${#personal_deferred[@]} -gt 0 ]; then
    printf '%d declared skill(s) left to the same version in %s.\n' \
      $((${#personal_deferred[@]} / 3)) "$personal_dir"
  fi
  if [ "$personal_check" = strict ] && [ "$personal_mismatches" -gt 0 ]; then
    printf '%s: %d declared skill(s) differ from the personal scope'"'"'s copy (--strict).\n' \
      "$app_name" "$personal_mismatches" >&2
    exit 1
  fi
}
