#!/usr/bin/env bats
# The shared skill-layout check on the fixture repositories
# tests/example-skill-checks-good and tests/example-skill-checks-bad.
# Inputs: SKILL_LAYOUT_CHECK — the check's program
#         GOOD_SETTINGS, GOOD_SKILLS — the good fixture's settings file and
#           skills folder, as lib/skill-checks.nix makes them for the check
#         BAD_SETTINGS, BAD_SKILLS — the same for the bad fixture, in which
#           each skill breaks one rule
setup() { source "$BATS_HELPERS"; }

check_bad() { run "$SKILL_LAYOUT_CHECK" --settings "${1:-$BAD_SETTINGS}" "$BAD_SKILLS"; }

@test "a repository that keeps every rule passes, two skills' packages among it" {
  run "$SKILL_LAYOUT_CHECK" --settings "$GOOD_SETTINGS" "$GOOD_SKILLS"
  assert_success
  assert_output "skill-layout: every skill under $GOOD_SKILLS passes"
}

@test "a test folder in a skill fails the check, naming the skill and test-folders" {
  check_bad
  assert_failure 1
  assert_line "has-test-folder: tests is a test folder; tests go in tests/has-test-folder/ (test-folders)"
}

@test "a test file in a skill fails the check, naming the skill and test-files" {
  check_bad
  assert_failure 1
  assert_line "has-test-file: scripts/run.bats is a test file; tests go in tests/has-test-file/ (test-files)"
  assert_line "has-test-file: scripts/test_helper.py is a test file; tests go in tests/has-test-file/ (test-files)"
}

@test "a script importing a library fails the check, though a skill folder bears its name" {
  check_bad
  assert_failure 1
  assert_line "imports-a-library: scripts/fetch.py:2: imports yaml, which is neither the standard library nor a module beside it (standard-library-imports)"
}

@test "a script importing a library pylint runs on fails the check, naming the skill and standard-library-imports" {
  check_bad
  assert_failure 1
  assert_line "imports-a-pylint-dependency: scripts/format_toml.py:1: imports tomlkit, which is neither the standard library nor a module beside it (standard-library-imports)"
}

@test "a script importing a module removed from the standard library fails the check, naming the skill and standard-library-imports" {
  check_bad
  assert_failure 1
  assert_line "imports-a-removed-module: scripts/legacy.py:1: Unable to import 'imp' (standard-library-imports)"
}

@test "a pylint comment disabling the import error on the line fails the check" {
  check_bad
  assert_failure 1
  assert_line "imports-a-removed-module: scripts/disabled.py:1: has a pylint control comment, which could hide a module pylint can't import; remove it (standard-library-imports)"
}

@test "a pylint comment skipping the whole file fails the check" {
  check_bad
  assert_failure 1
  assert_line "imports-a-removed-module: scripts/skipped.py:1: has a pylint control comment, which could hide a module pylint can't import; remove it (standard-library-imports)"
}

@test "a pylint comment written in the script's own coding, UTF-7, fails the check" {
  check_bad
  assert_failure 1
  assert_line "imports-a-removed-module: scripts/encoded.py:2: has a pylint control comment, which could hide a module pylint can't import; remove it (standard-library-imports)"
}

@test "a pylint control comment's text in a string is no comment and passes" {
  run "$SKILL_LAYOUT_CHECK" --settings "$GOOD_SETTINGS" "$GOOD_SKILLS"
  assert_success
  assert_file_contains "$GOOD_SKILLS/trigger-skill/scripts/message.py" '"# pylint: disable=import-error"'
  refute_output --partial message.py
}

@test "a module and a package linked into scripts/ import, and links outside the skill or to nothing pass" {
  run "$SKILL_LAYOUT_CHECK" --settings "$GOOD_SETTINGS" "$GOOD_SKILLS"
  assert_success
  assert_link_exists "$GOOD_SKILLS/trigger-skill/scripts/linked_module.py"
  assert_link_exists "$GOOD_SKILLS/trigger-skill/scripts/linked_package"
  assert_link_exists "$GOOD_SKILLS/trigger-skill/scripts/zlib.so"
  assert_link_exists "$GOOD_SKILLS/trigger-skill/scripts/outside.py"
  assert_link_exists "$GOOD_SKILLS/trigger-skill/scripts/dangling.py"
  refute_output --partial trigger-skill
}

@test "a compiled module a skill ships beside its scripts never loads" {
  run "$SKILL_LAYOUT_CHECK" --settings "$GOOD_SETTINGS" "$GOOD_SKILLS"
  assert_success
  assert_file_exists "$GOOD_SKILLS/plain-skill/scripts/sqlite3.so"
  refute_output --partial sqlite3
}

@test "a script Python can't parse fails the check, naming the skill and python-syntax" {
  check_bad
  assert_failure 1
  assert_line --regexp "^unparsable-script: scripts/old_print.py:1: Parsing failed: .* \(python-syntax\)$"
}

@test "a relative import fails the check, though the skill's ruff.toml and a noqa comment would allow it" {
  check_bad
  assert_failure 1
  assert_line "relative-import: scripts/relative.py:1: imports relative to a package; import a module beside the script by its name (relative-imports)"
  assert_line "relative-import: scripts/relative.py:2: imports relative to a package; import a module beside the script by its name (relative-imports)"
}

@test "two skills' scripts of one module name fail the check, naming the skill and unique-script-modules" {
  check_bad
  assert_failure 1
  assert_line "shares-module-two: scripts/common.py has the module name common, as shares-module-one/scripts/common.py has (unique-script-modules)"
}

@test "a folder in tests/ naming no skill fails the check, naming it and tests-name-skills" {
  check_bad
  assert_failure 1
  assert_line "tests/no-such-skill: names no skill (tests-name-skills)"
}

@test "the bad fixture's problems are the ones above and no others" {
  check_bad
  assert_failure 1
  assert_equal "${#lines[@]}" 14
}

@test "a rule set off in the settings reports nothing" {
  jq '.layout += {"test-folders": [], "test-files": [], "unique-script-modules": false, "tests-name-skills": false}' \
    "$BAD_SETTINGS" >"$BATS_TEST_TMPDIR/settings.json"
  check_bad "$BATS_TEST_TMPDIR/settings.json"
  assert_failure 1
  refute_line --partial "(test-folders)"
  refute_line --partial "(test-files)"
  refute_line --partial "(unique-script-modules)"
  refute_line --partial "(tests-name-skills)"
  assert_equal "${#lines[@]}" 9
}

@test "a call without a settings file or a skills folder is a usage error" {
  run "$SKILL_LAYOUT_CHECK" "$GOOD_SKILLS"
  assert_failure 2
  assert_output --partial "Usage: skill-layout-check"
}
