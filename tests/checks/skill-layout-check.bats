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

@test "a repository that keeps every rule passes" {
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

@test "a script importing a library fails the check, naming the skill and standard-library-imports" {
  check_bad
  assert_failure 1
  assert_line "imports-a-library: scripts/fetch.py:2 imports yaml, which is neither the standard library nor a module beside it (standard-library-imports)"
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
  assert_equal "${#lines[@]}" 6
}

@test "a rule set off in the settings reports nothing" {
  jq '.layout += {"test-folders": [], "test-files": [], "unique-script-modules": false, "tests-name-skills": false}' \
    "$BAD_SETTINGS" >"$BATS_TEST_TMPDIR/settings.json"
  check_bad "$BATS_TEST_TMPDIR/settings.json"
  assert_failure 1
  assert_output "imports-a-library: scripts/fetch.py:2 imports yaml, which is neither the standard library nor a module beside it (standard-library-imports)"
}

@test "a call without a settings file or a skills folder is a usage error" {
  run "$SKILL_LAYOUT_CHECK" "$GOOD_SKILLS"
  assert_failure 2
  assert_output --partial "Usage: skill-layout-check"
}
