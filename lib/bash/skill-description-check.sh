# skill-description-check: every skill's SKILL.md frontmatter, its
# description and its relative links. Run by
# `checks.<system>.skill-description` (lib/skill-checks.nix), which writes
# the settings file. Needs coreutils, gnugrep, jq, yq-go and lychee.

usage() {
  cat <<'EOF'
Usage: skill-description-check --settings <settings.json> <skills-dir>

Checks every skill folder under <skills-dir>, each rule named in brackets:

- the folder name is lowercase words joined by hyphens, at most 64
  characters [folder-name];
- it holds a SKILL.md [skill-md] that opens with a frontmatter block
  between `---` lines, which is a YAML mapping [frontmatter];
- the frontmatter's `name` is the folder name [name];
- its `description` is a non-empty string of at most 1,024 characters
  [description];
- a skill in the `trigger-first` setting has a description that opens on
  `trigger-first-prefix` and stays within 500 characters, and each name
  in that setting is a skill's [trigger-first];
- with `skill-flake` on, the skill's own flake.nix builds it with
  mkSkillFlake under its folder name [skill-flake];
- with `relative-links` on, every relative link in SKILL.md outside a
  code block names a file inside the skill's folder [relative-links].

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
    echo "skill-description-check: unknown option $1" >&2
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

# Each command substitution is assigned before use, so a failing command
# stops the check under errexit rather than reading as "no problem".
description_settings=$(jq -c .description "$settings")
skill_flakes=$(jq -c '.repository."skill-flakes"' "$settings")
skill_flake=$(jq -r '."skill-flake"' <<<"$description_settings")
relative_links=$(jq -r '."relative-links"' <<<"$description_settings")
trigger_first=$(jq -r '."trigger-first"[]' <<<"$description_settings")
work=$(mktemp -d)

problems=()
# add_problems <text>: each line of the text, none for empty text.
add_problems() {
  local found=()
  [ -z "$1" ] || mapfile -t found <<<"$1"
  problems+=("${found[@]}")
}

# frontmatter_problems <skill>: the problems with the frontmatter JSON on
# stdin, one line each.
frontmatter_problems() {
  jq -r --arg skill "$1" --argjson settings "$description_settings" '
    def problem($what; $rule): "\($skill): \($what) (\($rule))";
    if type != "object" then
      problem("frontmatter is \({"null": "empty", "array": "a list"}[type] // "a \(type)"), not a mapping"; "frontmatter")
    else
      (if .name != $skill then
        problem("frontmatter name is \(.name | tojson), not the folder name"; "name")
      else empty end),
      (.description as $d
      | if $d == null then problem("frontmatter has no description"; "description")
        elif ($d | type) != "string" then problem("description is \($d | tojson), not a string"; "description")
        elif ($d | test("^\\s*$")) then problem("description is empty"; "description")
        else
          (if ($d | length) > 1024 then
            problem("description is \($d | length) characters, over 1024"; "description")
          else empty end),
          (if any($settings."trigger-first"[]; . == $skill) then
            (if ($d | startswith($settings."trigger-first-prefix")) then empty else
              problem("description does not open on \($settings."trigger-first-prefix" | tojson), saying when to load the skill"; "trigger-first")
            end),
            (if ($d | length) > 500 then
              problem("description is \($d | length) characters, over the trigger-first 500"; "trigger-first")
            else empty end)
          else empty end)
        end)
    end'
}

# link_problems <skill> <skill folder>: lychee's offline check of SKILL.md's
# links, in a copy of the skill alone, so a link out of the skill finds no
# file. lychee runs from an empty folder, so no lychee.toml or .lycheeignore
# a skill ships configures it, and leaves out links in code blocks and code
# spans.
link_problems() {
  local skill=$1 parent empty report status=0
  parent=$(mktemp -d "$work/links.XXXXXX")
  empty=$(mktemp -d "$work/empty.XXXXXX")
  cp -R "$2" "$parent/$skill"
  parent=$(cd "$parent" && pwd -P)
  report=$(cd "$empty" && lychee --offline --no-progress --format json "$parent/$skill/SKILL.md") || status=$?
  if [ "$status" != 0 ] && [ "$status" != 2 ]; then
    echo "skill-description-check: lychee failed with status $status on $skill" >&2
    exit 2
  fi
  jq -r --arg skill "$skill" --arg parent "$parent" '
    .error_map[]?[]
    | (.url | ltrimstr("file://")) as $path
    | if ($path | startswith("\($parent)/\($skill)/")) then
        "\($skill): SKILL.md links to \($path | ltrimstr("\($parent)/\($skill)/")), which is not in the skill (relative-links)"
      elif ($path | startswith("\($parent)/")) then
        "\($skill): SKILL.md links to ../\($path | ltrimstr("\($parent)/")), outside the skill (relative-links)"
      else
        "\($skill): SKILL.md has a link that names no file in the skill: \(.status.text) (relative-links)"
      end
  ' <<<"$report"
}

# flake_problems <skill>: whether the skill's own flake.nix builds it under
# its folder name, from the `skillName` lib/skill-checks.nix read.
flake_problems() {
  jq -r --arg skill "$1" '
    if has($skill) | not then "\($skill): has no flake.nix (skill-flake)"
    elif .[$skill] == null then "\($skill): flake.nix does not build the skill with mkSkillFlake (skill-flake)"
    elif .[$skill] != $skill then "\($skill): flake.nix builds it as skillName \(.[$skill] | tojson), not the folder name (skill-flake)"
    else empty end
  ' <<<"$skill_flakes"
}

check_skill() {
  local dir=$1 skill=$2 md=$1/SKILL.md frontmatter first out
  if ! [[ $skill =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || [ ${#skill} -gt 64 ]; then
    problems+=("$skill: the folder name is not lowercase words joined by hyphens, at most 64 characters (folder-name)")
  fi
  if [ ! -f "$md" ]; then
    problems+=("$skill: has no SKILL.md (skill-md)")
    return
  fi
  # A `---` line may end in CR, for a SKILL.md with CRLF line endings.
  first=$(head -n 1 "$md")
  if [ "${first%$'\r'}" != --- ] || ! grep -qxE -e $'---\r?' < <(tail -n +2 "$md"); then
    problems+=("$skill: SKILL.md does not open with a frontmatter block between --- lines (frontmatter)")
  elif ! frontmatter=$(yq --front-matter=extract -o=json . "$md" 2>&1); then
    frontmatter=$(tr -s '\n' ' ' <<<"${frontmatter##*SKILL.md\': }")
    problems+=("$skill: frontmatter is not valid YAML: ${frontmatter% } (frontmatter)")
  else
    out=$(frontmatter_problems "$skill" <<<"$frontmatter")
    add_problems "$out"
  fi
  if [ "$skill_flake" = true ]; then
    out=$(flake_problems "$skill")
    add_problems "$out"
  fi
  if [ "$relative_links" = true ]; then
    out=$(link_problems "$skill" "$dir")
    add_problems "$out"
  fi
}

for dir in "$skills"/*/; do
  dir=${dir%/}
  [ -d "$dir" ] || continue
  check_skill "$dir" "${dir##*/}"
done

listed_skills=()
[ -z "$trigger_first" ] || mapfile -t listed_skills <<<"$trigger_first"
for listed in "${listed_skills[@]}"; do
  [ -d "$skills/$listed" ] ||
    problems+=("$listed: listed in trigger-first, but there is no such skill (trigger-first)")
done

if [ ${#problems[@]} -gt 0 ]; then
  printf '%s\n' "${problems[@]}"
  exit 1
fi
echo "skill-description: every skill under $skills passes"
