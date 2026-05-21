#!/usr/bin/env bats
# Inputs: SKILL_ROOT — install root of a build with NO extraFiles.
# Regression guard for the default-strict whitelist posture.
setup() { source "$BATS_HELPERS"; }

@test "without extraFiles, loose top-level files are dropped" {
  assert [ -f "$SKILL_ROOT/SKILL.md" ]
  assert [ -f "$SKILL_ROOT/references/note.md" ]
  refute [ -e "$SKILL_ROOT/visual-companion.md" ]
  refute [ -e "$SKILL_ROOT/helper.sh" ]
  refute [ -e "$SKILL_ROOT/graph.dot" ]
  refute [ -e "$SKILL_ROOT/companion-dir" ]
}
