# flake-checks — list and build this flake's checks one at a time.
#
# `nix flake check` builds every check; this tool names them and builds
# the ones you pick, so a failing bats suite reruns in seconds. The nix
# on the caller's PATH does the work; this script only builds the
# command lines. Wrapped by scripts/default.nix (writeShellApplication).

usage() {
  cat <<'EOF'
Usage: flake-checks <command> [options] [name ...]

Commands:
  list            Print the name of every check for this system.
  run <name>...   Build the named checks with full build logs (-L).
  all             Build every check (nix flake check -L).
  help            Show this help and exit.

Options:
  --flake <ref>      Flake to check (default: the checkout's git top level,
                     or $PRJ_ROOT outside git).
  --system <system>  Nix system whose checks to use (default: the current one).
  --dry-run          Print the nix command instead of running it.
  -h, --help         Show this help and exit.

Exit status: 0 when every check builds, the nix exit status when one
fails, 2 for a usage error.
EOF
}

die_usage() {
  printf 'flake-checks: %s\n' "$1" >&2
  printf "Run 'flake-checks --help' for usage.\n" >&2
  exit 2
}

# default_flake — the checkout this runs in, so a worktree checks itself
# rather than the checkout the dev shell was entered from.
default_flake() {
  git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "${PRJ_ROOT:-$PWD}"
}

current_system() {
  nix eval --impure --raw --expr builtins.currentSystem
}

# check_installable <flake> <system> <name> — the attribute `run` builds.
check_installable() {
  printf '%s#checks.%s.%s\n' "$1" "$2" "$3"
}

# valid_check_name <name> — a bare attribute name, so it can't reach out
# of `checks.<system>` or be read by nix as a flag.
valid_check_name() {
  [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_\'-]*$ ]]
}

# execute <cmd...> — run it, or print it under --dry-run.
execute() {
  if [ "$dry_run" = 1 ]; then
    printf '%q ' "$@" | sed 's/ $//'
    printf '\n'
  else
    "$@"
  fi
}

command=""
flake=""
system=""
dry_run=0
names=()

while [ $# -gt 0 ]; do
  case $1 in
  -h | --help | help)
    usage
    exit 0
    ;;
  --dry-run) dry_run=1 ;;
  --flake)
    [ $# -ge 2 ] || die_usage "--flake needs a value"
    flake=$2
    shift
    ;;
  --flake=*) flake=${1#--flake=} ;;
  --system)
    [ $# -ge 2 ] || die_usage "--system needs a value"
    system=$2
    shift
    ;;
  --system=*) system=${1#--system=} ;;
  -*) die_usage "unknown option: $1" ;;
  *)
    if [ -z "$command" ]; then
      command=$1
    else
      names+=("$1")
    fi
    ;;
  esac
  shift
done

case $command in
list | run | all) ;;
"") die_usage "no command given" ;;
*) die_usage "unknown command: $command" ;;
esac

[ -n "$flake" ] || flake=$(default_flake)

case $command in
list)
  [ ${#names[@]} -eq 0 ] || die_usage "list takes no names"
  [ -n "$system" ] || system=$(current_system)
  execute nix eval --raw "$flake#checks.$system" \
    --apply 'cs: builtins.concatStringsSep "\n" (builtins.attrNames cs) + "\n"'
  ;;
run)
  [ ${#names[@]} -gt 0 ] || die_usage "run needs at least one check name (see: flake-checks list)"
  for name in "${names[@]}"; do
    valid_check_name "$name" || die_usage "not a check name: $name"
  done
  [ -n "$system" ] || system=$(current_system)
  installables=()
  for name in "${names[@]}"; do
    installables+=("$(check_installable "$flake" "$system" "$name")")
  done
  execute nix build --no-link -L "${installables[@]}"
  ;;
all)
  [ ${#names[@]} -eq 0 ] || die_usage "all takes no names; use run to pick checks"
  if [ -n "$system" ]; then
    execute nix flake check -L "$flake" --system "$system"
  else
    execute nix flake check -L "$flake"
  fi
  ;;
esac
