#!/usr/bin/env bats
# The shared skill-layout check on the fixture repositories
# tests/example-skill-checks-good, tests/example-skill-checks-bad,
# tests/example-skill-checks-loop and tests/example-skill-checks-empty.
# Inputs: SKILL_LAYOUT_CHECK — the check's program
#         GOOD_SETTINGS, GOOD_SKILLS — the good fixture's settings file and
#           skills folder, as lib/skill-checks.nix makes them for the check
#         BAD_SETTINGS, BAD_SKILLS — the same for the bad fixture, in which
#           each skill breaks one rule
#         LOOP_SETTINGS, LOOP_SKILLS — the same for the loop fixture, whose
#           skill's scripts/ holds a link to itself
#         EMPTY_SETTINGS, EMPTY_SKILLS — the same for the empty fixture,
#           whose skills folder holds no skill
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

@test "a module linked into scripts/ imports, and links outside the skill or to nothing pass" {
  run "$SKILL_LAYOUT_CHECK" --settings "$GOOD_SETTINGS" "$GOOD_SKILLS"
  assert_success
  assert_link_exists "$GOOD_SKILLS/trigger-skill/scripts/linked_module.py"
  assert_link_exists "$GOOD_SKILLS/trigger-skill/scripts/outside.py"
  assert_link_exists "$GOOD_SKILLS/trigger-skill/scripts/dangling.py"
  refute_output --partial trigger-skill
}

@test "a link named like a test folder or a test file fails the check, whatever it points at" {
  check_bad
  assert_failure 1
  assert_link_exists "$BAD_SKILLS/has-test-link/tests"
  assert_link_exists "$BAD_SKILLS/has-test-link/run.bats"
  assert_link_exists "$BAD_SKILLS/has-test-link/test_gone.py"
  assert_line "has-test-link: tests is a test folder; tests go in tests/has-test-link/ (test-folders)"
  assert_line "has-test-link: run.bats is a test file; tests go in tests/has-test-link/ (test-files)"
  assert_line "has-test-link: test_gone.py is a test file; tests go in tests/has-test-link/ (test-files)"
}

@test "a link named like a test folder fails the check though it points at a file" {
  check_bad
  assert_failure 1
  assert_link_exists "$BAD_SKILLS/has-test-link/notes/tests"
  assert_file_exists "$BAD_SKILLS/has-test-link/notes/plan.md"
  assert_line "has-test-link: notes/tests is a test folder; tests go in tests/has-test-link/ (test-folders)"
}

@test "a folder whose name starts with a dot fails the check, naming dot-folders, and a dot file passes" {
  check_bad
  assert_failure 1
  assert_dir_exists "$BAD_SKILLS/.hidden-skill"
  assert_file_exists "$BAD_SKILLS/.preferences.md"
  assert_line ".hidden-skill: the folder name starts with a dot; the checks pass over it, but agent-skill-flake builds skills from it (dot-folders)"
  refute_line --partial ".preferences.md"
}

@test "a link whose name starts with a dot passes dot-folders, whatever it points at" {
  check_bad
  assert_failure 1
  assert_link_exists "$BAD_SKILLS/.linked-skill"
  refute_line --partial ".linked-skill"
}

@test "a folder or module in scripts/ named after a standard-library module fails the check, naming standard-library-names" {
  check_bad
  assert_failure 1
  assert_link_exists "$BAD_SKILLS/shadows-standard-library/scripts/csv"
  assert_line "shadows-standard-library: scripts/csv has the name of the standard library's csv (standard-library-names)"
  assert_line "shadows-standard-library: scripts/html has the name of the standard library's html (standard-library-names)"
  assert_line "shadows-standard-library: scripts/json has the name of the standard library's json (standard-library-names)"
  assert_line "shadows-standard-library: scripts/secrets.py has the name of the standard library's secrets (standard-library-names)"
  refute_line --partial "shadows-standard-library: scripts/use_names.py"
}

@test "a folder whose parent folder holds no script passes standard-library-names, though named after a standard-library module" {
  check_bad
  assert_failure 1
  assert_dir_exists "$BAD_SKILLS/shadows-standard-library/scripts/templates/html"
  refute_line --partial "scripts/templates/html"
}

@test "a script importing a folder beside it, a package, a namespace package or a linked package, fails the check" {
  check_bad
  assert_failure 1
  assert_dir_exists "$BAD_SKILLS/imports-a-package/scripts/space"
  assert_link_exists "$BAD_SKILLS/imports-a-package/scripts/linked_package"
  assert_line "imports-a-package: scripts/use_packages.py:3: imports bundled, a folder beside it; a script imports only the standard library and the .py modules beside it (standard-library-imports)"
  assert_line "imports-a-package: scripts/use_packages.py:4: imports space, a folder beside it; a script imports only the standard library and the .py modules beside it (standard-library-imports)"
  assert_line "imports-a-package: scripts/use_packages.py:5: imports linked_package, a folder beside it; a script imports only the standard library and the .py modules beside it (standard-library-imports)"
}

@test "a script importing a folder beside it named empty fails the check, whatever the tools' own folder is named" {
  check_bad
  assert_failure 1
  assert_file_exists "$BAD_SKILLS/imports-a-package/scripts/empty/__init__.py"
  assert_line "imports-a-package: scripts/use_packages.py:6: imports empty, a folder beside it; a script imports only the standard library and the .py modules beside it (standard-library-imports)"
}

@test "a compiled module in scripts/, a file or a link, fails the check, naming compiled-modules, and never loads" {
  check_bad
  assert_failure 1
  assert_file_exists "$BAD_SKILLS/ships-compiled-module/scripts/sqlite3.so"
  assert_link_exists "$BAD_SKILLS/ships-compiled-module/scripts/zlib.so"
  assert_line "ships-compiled-module: scripts/sqlite3.so is a compiled module; a skill's scripts import only the standard library and .py modules (compiled-modules)"
  assert_line "ships-compiled-module: scripts/zlib.so is a compiled module; a skill's scripts import only the standard library and .py modules (compiled-modules)"
  refute_line --partial "ships-compiled-module: scripts/use_compiled.py"
}

@test "a .pyd, a .pyc and a .so in a folder under scripts/ fail the check, naming compiled-modules" {
  check_bad
  assert_failure 1
  assert_line "ships-compiled-module: scripts/speedups.pyd is a compiled module; a skill's scripts import only the standard library and .py modules (compiled-modules)"
  assert_line "ships-compiled-module: scripts/sqlite3.pyc is a compiled module; a skill's scripts import only the standard library and .py modules (compiled-modules)"
  assert_line "ships-compiled-module: scripts/native/fast.so is a compiled module; a skill's scripts import only the standard library and .py modules (compiled-modules)"
}

@test "a link loop in scripts/ stops the check with status 2, naming the skill and walkable-scripts" {
  run "$SKILL_LAYOUT_CHECK" --settings "$LOOP_SETTINGS" "$LOOP_SKILLS"
  assert_failure 2
  assert_link_exists "$LOOP_SKILLS/link-loop/scripts/loop"
  assert_output "link-loop: find can't walk scripts/: File system loop detected; 'link-loop/scripts/loop' is part of the same file system loop as 'link-loop/scripts'. (walkable-scripts)"
}

@test "a skills folder that holds no skill fails the check, naming skills-exist" {
  run "$SKILL_LAYOUT_CHECK" --settings "$EMPTY_SETTINGS" "$EMPTY_SKILLS"
  assert_failure 1
  assert_file_exists "$EMPTY_SKILLS/.gitkeep"
  assert_output "skills: holds no skill folder (skills-exist)"
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
  assert_equal "${#lines[@]}" 32
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
  assert_equal "${#lines[@]}" 23
}

@test "a call without a settings file or a skills folder is a usage error" {
  run "$SKILL_LAYOUT_CHECK" "$GOOD_SKILLS"
  assert_failure 2
  assert_output --partial "Usage: skill-layout-check"
}
