#!/usr/bin/env bats
# Inputs: SKILL_ROOT — install root of a build with
#         extraFiles = [ "*.nonexistent" "@v2@*.nonexistent" ]
# Non-matching globs are silently dropped (nullglob), so the install
# looks identical to the no-extraFiles case. The build succeeding at
# all shows an `@…@` entry isn't taken for a replaceVars placeholder.
setup() { source "$BATS_HELPERS"; }

@test "no-match glob produces only the canonical surface" {
  assert [ -f "$SKILL_ROOT/SKILL.md" ]
  assert [ -f "$SKILL_ROOT/references/note.md" ]
  refute [ -e "$SKILL_ROOT/visual-companion.md" ]
  refute [ -e "$SKILL_ROOT/helper.sh" ]
  refute [ -e "$SKILL_ROOT/graph.dot" ]
  # The literal pattern must NOT be copied as a filename.
  refute [ -e "$SKILL_ROOT/*.nonexistent" ]
  refute [ -e "$SKILL_ROOT/@v2@*.nonexistent" ]
}
