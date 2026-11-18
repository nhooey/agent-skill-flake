# skill-layout-check: the layout of a skill repository's skills folder.
# Run by `checks.<system>.skill-layout` (lib/skill-checks.nix), which
# writes the settings file and sets SKILL_CHECKS_PYLINTRC and
# SKILL_CHECKS_RUFF to the tools' settings in lib/config/. Needs coreutils,
# findutils, jq, python3, fawltydeps, pylint and ruff.

usage() {
  cat <<'EOF'
Usage: skill-layout-check --settings <settings.json> <skills-dir>

Checks the skill folders under <skills-dir>, each rule named in brackets:

- it holds a skill folder [skills-exist], and no folder whose name
  starts with a dot [dot-folders];
- no test folder [test-folders] or test file [test-files] sits under it,
  a link named like one among them, whatever it points at;
- each skill's Python scripts, scripts/**/*.py, import only the standard
  library of the Python running the check and the .py modules beside
  them, no folder beside them, with no `# pylint:` comment to hide one
  [standard-library-imports], parse [python-syntax], and import nothing
  relative to a package [relative-imports];
- no .py module in a skill's scripts/, or folder beside a script, has
  the name of a module in the checking Python's standard library
  [standard-library-names];
- no compiled module, *.so, *.pyd or *.pyc, sits in a skill's scripts/
  [compiled-modules];
- no two scripts share a module name [unique-script-modules];
- every folder directly under the repository's tests/ is named after a
  skill [tests-name-skills].

<settings.json> holds the merged settings and what lib/skill-checks.nix
read from the repository. Prints one line per problem,
"<skill>: <problem> (<rule>)", and exits 1 when there is any. Anything
find reports it can't walk in a skill's scripts/, such as a link that
loops back to a folder above it, stops the check with status 2 and a
line naming the skill [walkable-scripts].
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
skills=$(realpath "$skills")

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
skills_dir=$(jq -r '."skills-dir"' "$settings")
out=$(jq -r '.repository.tests[]' "$settings")
lines "$out"
test_dirs=("${LINES[@]}")

# A tool's error output, and the tools' copies and empty folder below.
temp=$(mktemp -d)
temp=$(realpath "$temp")
logs=$temp/logs
mkdir "$logs"

cd "$skills"

# ── The skills folder holds a skill ─────────────────────────────────────
# A skill is a folder, not a link to one, that isn't hidden or Python's
# cache, as lib/skill-checks.nix counts them.
out=$(find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name __pycache__ -print -quit)
[ -n "$out" ] || problems+=("$skills_dir: holds no skill folder (skills-exist)")

# ── No folder in it starts with a dot ───────────────────────────────────
# agent-skill-flake builds each folder in the skills folder that holds a
# SKILL.md as a skill and searches the others for skills, whatever its
# name, while the checks pass over a folder whose name starts with a dot.
# A link isn't followed there, and a file, such as a .gitkeep, is no skill.
out=$(find . -mindepth 1 -maxdepth 1 -type d -name '.*' -printf '%P\n' | sort)
lines "$out"
for folder in "${LINES[@]}"; do
  problems+=("$folder: the folder name starts with a dot; the checks pass over it, but agent-skill-flake builds skills from it (dot-folders)")
done

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

# A link is named like a test folder or a test file whatever it points at,
# a folder, a file or nothing, so each name test takes links too.
find_args=(. -name __pycache__ -prune)
if [ ${#test_folders[@]} -gt 0 ]; then
  name_tests "${test_folders[@]}"
  find_args+=(-o '(' -type d -o -type l ')' '(' "${NAME_TESTS[@]}" ')' -printf 'folder\t%P\n' -prune)
fi
if [ ${#test_files[@]} -gt 0 ]; then
  name_tests "${test_files[@]}"
  find_args+=(-o '(' -type f -o -type l ')' '(' "${NAME_TESTS[@]}" ')' -printf 'file\t%P\n')
fi
out=$(find "${find_args[@]}" | sort)
lines "$out"
for line in "${LINES[@]}"; do
  kind=${line%%$'\t'*}
  path=${line#*$'\t'}
  problems+=("${path%%/*}: ${path#*/} is a test $kind; tests go in tests/${path%%/*}/ (test-${kind}s)")
done

# tool_failed <tool> <status>: stop the check, since a tool that didn't run
# found nothing.
tool_failed() {
  echo "skill-layout-check: $1 failed with status $2" >&2
  exit 2
}

# ── What scripts/ holds: scripts, folders and compiled modules ───────────
# find follows links (-L), as Python's import does: a script, folder or
# compiled module linked into scripts/ counts as what it points at, and a
# link to nothing is left out, unless it is named like a compiled module.
# What find can't walk, such as a link that loops back to a folder above
# it or to itself, leaves it nothing to report beneath, so each line find
# writes about it stops the check, in find's own words.
scripts=()
folders=()
compiled=()
unwalkable=()
for scripts_dir in */scripts; do
  [ -d "$scripts_dir" ] || continue
  status=0
  out=$(find -L "$scripts_dir" -name __pycache__ -prune \
    -o -type d -printf 'folder\t%p\n' \
    -o -type f -name '*.py' -printf 'script\t%p\n' \
    -o '(' -name '*.so' -o -name '*.pyd' -o -name '*.pyc' ')' -printf 'compiled\t%p\n' \
    2>"$logs/find" | sort) || status=$?
  if [ "$status" != 0 ]; then
    errors=$(<"$logs/find")
    [ -n "$errors" ] || tool_failed find "$status"
    lines "$errors"
    for line in "${LINES[@]}"; do
      unwalkable+=("${scripts_dir%%/*}: find can't walk scripts/: ${line#find: } (walkable-scripts)")
    done
  fi
  lines "$out"
  for line in "${LINES[@]}"; do
    path=${line#*$'\t'}
    case ${line%%$'\t'*} in
    folder) folders+=("$path") ;;
    script) scripts+=("$path") ;;
    compiled) compiled+=("$path") ;;
    esac
  done
done
if [ ${#unwalkable[@]} -gt 0 ]; then
  printf '%s\n' "${problems[@]}" "${unwalkable[@]}"
  exit 2
fi

# ── No compiled module sits in scripts/ ─────────────────────────────────
# Python imports a compiled module beside a script, `sqlite3.so` or
# `sqlite3.pyc` say, before the standard library's module of its name.
for path in "${compiled[@]}"; do
  problems+=("${path%%/*}: ${path#*/} is a compiled module; a skill's scripts import only the standard library and .py modules (compiled-modules)")
done

# ── Scripts import only the standard library and their siblings ──────────
if [ ${#scripts[@]} -gt 0 ]; then
  # Each tool runs from an empty folder on absolute paths, so no folder or
  # settings file a skill ships changes what it finds. Each tool's findings
  # become lines of "<path under skills>\t<line>\t<message>\t<rule>". The
  # folder's name holds a dash, so it names no module: FawltyDeps takes its
  # --base-dir's own name as first-party and would report no import of it.
  scratch=$temp/no-imports
  copy=$temp/scripts
  mkdir "$scratch" "$copy"
  absolute=("${scripts[@]/#/$skills/}")

  # pylint puts each script's folder first on Python's path, and astroid
  # loads a compiled module it finds there before the standard library's
  # own, so pylint reads a copy of each scripts/ folder that holds only its
  # folders and .py files: a `sqlite3.so` a skill ships never loads. Links
  # are followed and copied as what they point at.
  for folder in "${folders[@]}"; do
    mkdir -p -- "$copy/$folder"
  done
  for script in "${scripts[@]}"; do
    cp -- "$script" "$copy/$script"
  done

  # A `# pylint:` comment switches pylint's messages off for a line, a
  # block or the whole file (`skip-file`), so it could hide a module that
  # Python can't import: a script with a comment that holds `pylint:`
  # fails, whatever it says. Python's tokenize reads the script as Python
  # does, decoding it by its coding line and telling comments from
  # strings; it prints a token a line, "<start>-<end>: <type> <repr>".
  # It stops at what it can't read, with status 1, and pylint reports that
  # script as python-syntax.
  pylint_comments=()
  for script in "${scripts[@]}"; do
    status=0
    out=$(python3 -I -m tokenize -- "$script" 2>"$logs/tokenize") || status=$?
    if [ "$status" -gt 1 ]; then
      cat "$logs/tokenize" >&2
      tool_failed tokenize "$status"
    fi
    lines "$out"
    for line in "${LINES[@]}"; do
      read -r range type text <<<"$line"
      if [ "$type" = COMMENT ] && [[ $text == *pylint:* ]]; then
        pylint_comments+=("$script"$'\t'"${range%%,*}"$'\t'"has a pylint control comment, which could hide a module pylint can't import; remove it"$'\t'standard-library-imports)
      fi
    done
  done
  controls=$(printf '%s\n' "${pylint_comments[@]}")

  cd "$scratch"

  # ── No module or folder beside a script has a standard-library name ───
  # A .py module in scripts/, or a folder beside a script, comes before
  # the standard library's module of its name on Python's path, and
  # FawltyDeps reports no import of a standard-library name. So a name in
  # the checking Python's sys.stdlib_module_names fails. A folder whose
  # parent folder holds no script is on no script's path.
  declare -A holds_script=()
  for script in "${scripts[@]}"; do
    holds_script[${script%/*}]=1
  done
  named=()
  for folder in "${folders[@]}"; do
    if [ -n "${holds_script[${folder%/*}]-}" ]; then
      named+=("$folder")
    fi
  done
  named+=("${scripts[@]}")
  declare -A standard=()
  out=$(python3 -I -c 'import sys; print(*sorted(sys.stdlib_module_names), sep="\n")')
  lines "$out"
  for name in "${LINES[@]}"; do
    standard[$name]=1
  done
  for path in "${named[@]}"; do
    name=${path##*/}
    name=${name%.py}
    if [ -n "${standard[$name]-}" ]; then
      problems+=("${path%%/*}: ${path#*/} has the name of the standard library's $name (standard-library-names)")
    fi
  done

  # FawltyDeps reports each import that isn't the standard library. With no
  # dependency declared, no Python environment to search and the empty
  # folder as its base for first-party modules, every such import is
  # undeclared, a module or folder beside the script and the libraries
  # pylint itself runs on among them. jq then drops each import of a .py
  # module beside the script, so a folder beside it, a package or a
  # namespace package, fails. FawltyDeps logs a script it can't parse and
  # goes on; pylint reports that script below.
  status=0
  report=$(fawltydeps --check-undeclared --json --code "${absolute[@]}" \
    --deps "$scratch" --pyenv "$scratch" --base-dir "$scratch" 2>"$logs/fawltydeps") || status=$?
  if [ "$status" != 0 ] && [ "$status" != 3 ]; then
    cat "$logs/fawltydeps" >&2
    tool_failed fawltydeps "$status"
  fi
  script_list=$(printf '%s\n' "${scripts[@]}")
  folder_list=$(printf '%s\n' "${folders[@]}")
  third_party=$(jq -r --arg root "$skills/" --arg scripts "$script_list" --arg folders "$folder_list" '
    ($scripts | split("\n")) as $scripts
    | ($folders | split("\n")) as $folders
    | .undeclared_deps[] | .name as $module | .references[]
    | (.path | ltrimstr($root)) as $path
    | ($path | sub("/[^/]*$"; "")) as $folder
    | select("\($folder)/\($module).py" | IN($scripts[]) | not)
    | [$path, .lineno,
       if "\($folder)/\($module)" | IN($folders[]) then
         "imports \($module), a folder beside it; a script imports only the standard library and the .py modules beside it"
       else
         "imports \($module), which is neither the standard library nor a module beside it"
       end,
       "standard-library-imports"] | @tsv
  ' <<<"$report")

  # pylint imports each module as the Python running the check would, with
  # the script's folder on the path, which FawltyDeps's version-blind list
  # of standard-library names doesn't: a module removed from the standard
  # library fails here, and so does a script that doesn't parse. pylint
  # puts the folder of every script it reads on Python's path, so it reads
  # one skill's scripts at a time, as each skill is installed alone: a
  # module one skill ships never hides another skill's import error.
  out=$(printf '%s\n' "${scripts[@]%%/*}" | sort -u)
  lines "$out"
  skill_names=("${LINES[@]}")
  unimportable=
  for skill in "${skill_names[@]}"; do
    skill_copies=()
    for script in "${scripts[@]}"; do
      if [[ $script == "$skill"/* ]]; then
        skill_copies+=("$copy/$script")
      fi
    done
    status=0
    report=$(PYLINTHOME=$(mktemp -d) pylint --rcfile "$SKILL_CHECKS_PYLINTRC" \
      --output-format json2 "${skill_copies[@]}") || status=$?
    [ $((status & 33)) = 0 ] || tool_failed pylint "$status"
    out=$(jq -r --arg root "$copy/" '
      .messages[]
      | [(.path | ltrimstr($root)), .line, .message,
         if .symbol == "syntax-error" then "python-syntax" else "standard-library-imports" end]
      | @tsv
    ' <<<"$report")
    unimportable+=$out$'\n'
  done

  # ruff reports every relative import, with `# noqa` comments ignored.
  status=0
  report=$(ruff check --no-cache --ignore-noqa --exit-zero --config "$SKILL_CHECKS_RUFF" \
    --output-format json "${absolute[@]}") || status=$?
  [ "$status" = 0 ] || tool_failed ruff "$status"
  relative=$(jq -r --arg root "$skills/" '
    .[] | select(.code == "TID252")
    | [(.filename | ltrimstr($root)), .location.row,
       "imports relative to a package; import a module beside the script by its name",
       "relative-imports"] | @tsv
  ' <<<"$report")

  cd "$skills"

  # A line FawltyDeps reports, pylint reports again when the module is
  # missing altogether; the FawltyDeps line says more.
  declare -A reported=()
  lines "$third_party"
  for line in "${LINES[@]}"; do
    IFS=$'\t' read -r path number _ <<<"$line"
    reported["$path:$number"]=1
  done
  out=$(printf '%s\n' "$third_party" "$unimportable" "$controls" "$relative" | sort -t $'\t' -k1,1 -k2,2n)
  lines "$out"
  for line in "${LINES[@]}"; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r path number message rule <<<"$line"
    if [ -n "${reported["$path:$number"]-}" ] && [[ $message == "Unable to import "* ]]; then
      continue
    fi
    problems+=("${path%%/*}: ${path#*/}:$number: $message ($rule)")
  done
fi

# ── No two scripts share a module name ──────────────────────────────────
if [ "$unique_script_modules" = true ]; then
  declare -A first_of=()
  for script in "${scripts[@]}"; do
    module=${script##*/}
    module=${module%.py}
    # A package's __init__.py is the module named after its folder.
    if [ "$module" = __init__ ]; then
      module=${script%/__init__.py}
      module=${module##*/}
    fi
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
