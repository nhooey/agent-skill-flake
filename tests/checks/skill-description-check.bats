#!/usr/bin/env bats
# The shared skill-description check on the fixture repositories
# tests/example-skill-checks-good, tests/example-skill-checks-bad and
# tests/example-skill-checks-flake.
# Inputs: SKILL_DESCRIPTION_CHECK — the check's program
#         GOOD_SETTINGS, GOOD_SKILLS — the good fixture's settings file and
#           skills folder, as lib/skill-checks.nix makes them for the check
#         BAD_SETTINGS, BAD_SKILLS — the same for the bad fixture, in which
#           each skill breaks one rule
#         FLAKE_SETTINGS, FLAKE_SKILLS — the same for the flake fixture,
#           whose skills each break the skill-flake rule
#         EMPTY_SETTINGS, EMPTY_SKILLS — the same for
#           tests/example-skill-checks-empty, whose skills folder holds no
#           skill
setup() { source "$BATS_HELPERS"; }

check_bad() { run "$SKILL_DESCRIPTION_CHECK" --settings "${1:-$BAD_SETTINGS}" "$BAD_SKILLS"; }

@test "a repository that keeps every rule passes, a SKILL.md with CRLF line endings among it" {
  run "$SKILL_DESCRIPTION_CHECK" --settings "$GOOD_SETTINGS" "$GOOD_SKILLS"
  assert_success
  assert_output "skill-description: every skill under $GOOD_SKILLS passes"
}

@test "a skill without a SKILL.md fails the check, naming the skill and skill-md" {
  check_bad
  assert_failure 1
  assert_line "no-skill-md: has no SKILL.md (skill-md)"
}

@test "a SKILL.md without a frontmatter block fails the check, naming the skill and frontmatter" {
  check_bad
  assert_failure 1
  assert_line "no-frontmatter: SKILL.md does not open with a frontmatter block between --- lines (frontmatter)"
  assert_line "unclosed-frontmatter: SKILL.md does not open with a frontmatter block between --- lines (frontmatter)"
}

@test "a frontmatter that isn't a YAML mapping fails the check, naming the skill and frontmatter" {
  check_bad
  assert_failure 1
  assert_line --regexp '^invalid-yaml: frontmatter is not valid YAML: yaml: line 2, column [0-9]+: mapping values are not allowed in this context \(frontmatter\)$'
  assert_line "list-frontmatter: frontmatter is a list, not a mapping (frontmatter)"
  assert_line "empty-frontmatter: frontmatter is empty, not a mapping (frontmatter)"
}

@test "a name other than the folder's fails the check, naming the skill and name" {
  check_bad
  assert_failure 1
  assert_line 'wrong-name: frontmatter name is "another-name", not the folder name (name)'
}

@test "a folder name that isn't lowercase words of at most 64 characters fails the check, naming the skill and folder-name" {
  check_bad
  assert_failure 1
  assert_line "Bad_Folder: the folder name is not lowercase words joined by hyphens, at most 64 characters (folder-name)"
  assert_line "a-folder-name-that-runs-past-the-sixty-four-character-limit-abcde: the folder name is not lowercase words joined by hyphens, at most 64 characters (folder-name)"
}

@test "a missing, empty, non-string or long description fails the check, naming the skill and description" {
  check_bad
  assert_failure 1
  assert_line "no-description: frontmatter has no description (description)"
  assert_line "number-description: description is 42, not a string (description)"
  assert_line "blank-description: description is empty (description)"
  assert_line --regexp '^long-description: description is 1[0-9]{3} characters, over 1024 \(description\)$'
}

@test "a trigger-first skill's description that misses the form fails the check, naming the skill and trigger-first" {
  check_bad
  assert_failure 1
  assert_line 'trigger-without-load: description does not open on "Load ", saying when to load the skill (trigger-first)'
  assert_line --regexp '^trigger-too-long: description is 5[0-9]{2} characters, over the trigger-first 500 \(trigger-first\)$'
  assert_line "no-such-skill: listed in trigger-first, but there is no such skill (trigger-first)"
}

@test "a link to a file the skill doesn't hold fails the check, though the skill's lychee settings would ignore it" {
  check_bad
  assert_failure 1
  assert_line "broken-link: SKILL.md links to missing.md, which is not in the skill (relative-links)"
  assert_line "broken-link: SKILL.md links to ../wrong-name/SKILL.md, outside the skill (relative-links)"
}

@test "the bad fixture's problems are the ones above and no others" {
  check_bad
  assert_failure 1
  assert_equal "${#lines[@]}" 18
}

@test "the trigger-first prefix is a setting" {
  jq '.description."trigger-first-prefix" = "Use when "' "$BAD_SETTINGS" >"$BATS_TEST_TMPDIR/settings.json"
  check_bad "$BATS_TEST_TMPDIR/settings.json"
  assert_failure 1
  refute_line --partial "trigger-without-load:"
  assert_line 'trigger-too-long: description does not open on "Use when ", saying when to load the skill (trigger-first)'
}

@test "relative-links set off reports no link" {
  jq '.description."relative-links" = false' "$BAD_SETTINGS" >"$BATS_TEST_TMPDIR/settings.json"
  check_bad "$BATS_TEST_TMPDIR/settings.json"
  assert_failure 1
  refute_line --partial "(relative-links)"
}

@test "a skill's own flake.nix that doesn't build it under its folder name fails the check, naming the skill and skill-flake" {
  run "$SKILL_DESCRIPTION_CHECK" --settings "$FLAKE_SETTINGS" "$FLAKE_SKILLS"
  assert_failure 1
  assert_line 'flake-other-name: flake.nix builds it as skillName "another-name", not the folder name (skill-flake)'
  assert_line "flake-missing: has no flake.nix (skill-flake)"
  assert_line "flake-without-mk-skill-flake: flake.nix does not build the skill with mkSkillFlake (skill-flake)"
  assert_equal "${#lines[@]}" 3
}

@test "a skills folder that holds no skill fails the check, naming skills-exist" {
  run "$SKILL_DESCRIPTION_CHECK" --settings "$EMPTY_SETTINGS" "$EMPTY_SKILLS"
  assert_failure 1
  assert_file_exists "$EMPTY_SKILLS/.gitkeep"
  assert_output "skills: holds no skill folder (skills-exist)"
}

@test "a call without a settings file or a skills folder is a usage error" {
  run "$SKILL_DESCRIPTION_CHECK" --settings "$GOOD_SETTINGS"
  assert_failure 2
  assert_output --partial "Usage: skill-description-check"
}
