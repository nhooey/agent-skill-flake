# scope.bash — shared install-scope resolver.
#
# Caller responsibilities (set before sourcing):
#   personal_suffix   — agent profile's $HOME-relative skill dir
#                       (e.g. ".claude/skills" for claude-code)
#   project_suffix    — agent profile's project-root-relative skill dir
#                       (e.g. ".claude/skills" for claude-code)
#   app_name          — used in error/usage text
#
# Sets after a successful parse:
#   target_root              — absolute path to install into
#   gcroots_dir              — absolute path to per-user GC-roots dir
#   scope_remaining_args[]   — argv with --scope/--root/--gcroots-dir stripped

# Walk up from $PWD looking for .git/ (preferred) or flake.nix (fallback).
# Echoes the project root and returns 0; returns 1 if not found.
find_project_root() {
  local git_root
  if git_root=$(git rev-parse --show-toplevel 2>/dev/null); then
    if [ -n "$git_root" ]; then
      printf '%s' "$git_root"
      return 0
    fi
  fi
  local dir="$PWD"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/flake.nix" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

# Parse --scope/--root/--gcroots-dir out of the argv. Other args pass
# through unchanged into the global `scope_remaining_args` array (the
# caller restores them with `set -- "${scope_remaining_args[@]}"`).
parse_scope_args() {
  scope_remaining_args=()
  local scope="" root="" gcroots=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --scope=*) scope="${1#--scope=}" ;;
    --scope)
      if [ $# -lt 2 ]; then
        printf '%s: --scope requires a value (personal|project|custom)\n' "$app_name" >&2
        return 2
      fi
      scope="$2"
      shift
      ;;
    --root=*) root="${1#--root=}" ;;
    --root)
      if [ $# -lt 2 ]; then
        printf '%s: --root requires a path\n' "$app_name" >&2
        return 2
      fi
      root="$2"
      shift
      ;;
    --gcroots-dir=*) gcroots="${1#--gcroots-dir=}" ;;
    --gcroots-dir)
      if [ $# -lt 2 ]; then
        printf '%s: --gcroots-dir requires a path\n' "$app_name" >&2
        return 2
      fi
      gcroots="$2"
      shift
      ;;
    *) scope_remaining_args+=("$1") ;;
    esac
    shift
  done

  case "$scope" in
  "")
    printf '%s: --scope is required (one of: personal, project, custom)\n' "$app_name" >&2
    printf '  See `%s --help` for usage.\n' "$app_name" >&2
    return 2
    ;;
  personal)
    if [ -n "$root" ]; then
      printf '%s: --root is only valid with --scope=custom (got --scope=personal)\n' "$app_name" >&2
      return 2
    fi
    target_root="$HOME/$personal_suffix"
    ;;
  project)
    if [ -n "$root" ]; then
      printf '%s: --root is only valid with --scope=custom (got --scope=project)\n' "$app_name" >&2
      return 2
    fi
    local proj
    if ! proj=$(find_project_root); then
      printf '%s: --scope=project but no project root found above PWD (%s).\n' "$app_name" "$PWD" >&2
      printf '  Searched for .git/ (preferred) or flake.nix (fallback).\n' >&2
      printf '  Use --scope=custom --root=<path> to install to an arbitrary directory.\n' >&2
      return 1
    fi
    target_root="$proj/$project_suffix"
    ;;
  custom)
    if [ -z "$root" ]; then
      printf '%s: --scope=custom requires --root=<path>\n' "$app_name" >&2
      return 2
    fi
    target_root="$root"
    ;;
  *)
    printf '%s: --scope must be personal, project, or custom (got: %s)\n' "$app_name" "$scope" >&2
    return 2
    ;;
  esac

  if [ -n "$gcroots" ]; then
    gcroots_dir="$gcroots"
  else
    gcroots_dir="/nix/var/nix/gcroots/per-user/$USER"
  fi
}

# Usage block shared by every app's --help. Prints to stdout.
print_scope_usage() {
  cat <<EOF
Install-scope flags (required):
  --scope=personal              Install at \$HOME/$personal_suffix
  --scope=project               Walk up from \$PWD for .git/ (preferred)
                                or flake.nix; install at
                                <project-root>/$project_suffix.
                                Hard error if no project root is found.
  --scope=custom --root=<path>  Install at <path> verbatim.

Other flags:
  --gcroots-dir=<path>          Override per-user GC-roots dir
                                (default: /nix/var/nix/gcroots/per-user/\$USER)
EOF
}
