# skill-layout-check: the layout of a skill repository's skills folder.
# Run by `checks.<system>.skill-layout` (lib/skill-checks.nix), which
# writes the settings file. Needs coreutils, findutils, jq and fawltydeps.

usage() {
  cat <<'EOF'
Usage: skill-layout-check --settings <settings.json> <skills-dir>

Checks the skill folders under <skills-dir>, each rule named in brackets
by its setting in skill-checks.toml:

- no test folder [test-folders] or test file [test-files] sits under it;
- each skill's Python scripts, scripts/**/*.py, import only the standard
  library and the modules beside them [standard-library-imports];
- no two scripts share a module name [unique-script-modules];
- every folder directly under the repository's tests/ is named after a
  skill [tests-name-skills].

<settings.json> holds the merged settings and what lib/skill-checks.nix
read from the repository. Prints one line per problem,
"<skill>: <problem> (<rule>)", and exits 1 when there is any.
EOF
}

settings=
skills=
while [ $# -gt 0 ]; do
  case $1 in
  --settings)
    settings=${2-}
    shift 2 || shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    echo "skill-layout-check: unknown option $1" >&2
    usage >&2
    exit 2
    ;;
  *)
    [ -z "$skills" ] || {
      usage >&2
      exit 2
    }
    skills=$1
    shift
    ;;
  esac
done
if [ -z "$settings" ] || [ -z "$skills" ]; then
  usage >&2
  exit 2
fi
settings=$(realpath "$settings")

# lines <text>: the text's lines into LINES, none for empty text.
lines() {
  LINES=()
  [ -z "$1" ] || mapfile -t LINES <<<"$1"
}

problems=()

# setting <key under .layout> -> the setting's value, a list one item a line.
setting() { jq -r --arg key "$1" '.layout[$key] | if type == "array" then .[] else . end' "$settings"; }

# Each command substitution is assigned before use, so a failing command
# stops the check under errexit rather than reading as "no problem".
out=$(setting test-folders)
lines "$out"
test_folders=("${LINES[@]}")
out=$(setting test-files)
lines "$out"
test_files=("${LINES[@]}")
unique_script_modules=$(setting unique-script-modules)
tests_name_skills=$(setting tests-name-skills)
out=$(jq -r '.repository.tests[]' "$settings")
lines "$out"
test_dirs=("${LINES[@]}")

cd "$skills"

# ── Tests sit in tests/<skill>/, never in the skill ──────────────────────

# name_tests <pattern>...: find's `-name <pattern>` tests joined by -o,
# into NAME_TESTS.
name_tests() {
  NAME_TESTS=()
  local pattern
  for pattern in "$@"; do
    [ ${#NAME_TESTS[@]} = 0 ] || NAME_TESTS+=(-o)
    NAME_TESTS+=(-name "$pattern")
  done
}

find_args=(. -name __pycache__ -prune)
if [ ${#test_folders[@]} -gt 0 ]; then
  name_tests "${test_folders[@]}"
  find_args+=(-o -type d '(' "${NAME_TESTS[@]}" ')' -printf 'folder\t%P\n' -prune)
fi
if [ ${#test_files[@]} -gt 0 ]; then
  name_tests "${test_files[@]}"
  find_args+=(-o -type f '(' "${NAME_TESTS[@]}" ')' -printf 'file\t%P\n')
fi
out=$(find "${find_args[@]}" | sort)
lines "$out"
for line in "${LINES[@]}"; do
  kind=${line%%$'\t'*}
  path=${line#*$'\t'}
  problems+=("${path%%/*}: ${path#*/} is a test $kind; tests go in tests/${path%%/*}/ (test-${kind}s)")
done

# ── Scripts import only the standard library and their siblings ──────────
scripts=()
for scripts_dir in */scripts; do
  [ -d "$scripts_dir" ] || continue
  out=$(find "$scripts_dir" -name __pycache__ -prune -o -type f -name '*.py' -print | sort)
  lines "$out"
  scripts+=("${LINES[@]}")
done

if [ ${#scripts[@]} -gt 0 ]; then
  # FawltyDeps reports each import that is neither the standard library nor
  # a first-party module, taking each --code file's own folder as where its
  # first-party modules are. With no dependency declared and no Python
  # environment to search, every such import is undeclared.
  nothing=$(mktemp -d)
  status=0
  report=$(fawltydeps --check-undeclared --json --code "${scripts[@]}" \
    --deps "$nothing" --pyenv "$nothing") || status=$?
  if [ "$status" != 0 ] && [ "$status" != 3 ]; then
    echo "skill-layout-check: fawltydeps failed with status $status" >&2
    exit 2
  fi
  out=$(jq -r '
    .undeclared_deps[] | .name as $module | .references[]
    | (.path | split("/")) as $parts
    | "\($parts[0]): \($parts[1:] | join("/")):\(.lineno) imports \($module), which is neither the standard library nor a module beside it (standard-library-imports)"
  ' <<<"$report" | sort)
  lines "$out"
  problems+=("${LINES[@]}")
fi

# ── No two scripts share a module name ──────────────────────────────────
if [ "$unique_script_modules" = true ]; then
  declare -A first_of=()
  for script in "${scripts[@]}"; do
    module=${script##*/}
    module=${module%.py}
    if [ -n "${first_of[$module]-}" ]; then
      problems+=("${script%%/*}: ${script#*/} has the module name $module, as ${first_of[$module]} has (unique-script-modules)")
    else
      first_of[$module]=$script
    fi
  done
fi

# ── Every folder in tests/ names a skill ────────────────────────────────
if [ "$tests_name_skills" = true ]; then
  for folder in "${test_dirs[@]}"; do
    [ -d "$folder" ] || problems+=("tests/$folder: names no skill (tests-name-skills)")
  done
fi

if [ ${#problems[@]} -gt 0 ]; then
  printf '%s\n' "${problems[@]}"
  exit 1
fi
echo "skill-layout: every skill under $skills passes"
