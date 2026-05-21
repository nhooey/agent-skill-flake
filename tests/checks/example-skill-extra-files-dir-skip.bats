#!/usr/bin/env bats
# Inputs: SKILL_ROOT — install root of a build with extraFiles = [ "*" ].
# The `[ -f "$f" ]` guard inside the install loop must skip the
# top-level `companion-dir/` (which is NOT in `extraDirs`) so only
# regular files at the source root are shipped.
setup() { source "$BATS_HELPERS"; }

@test "wildcard glob ships regular files but skips directories" {
  assert [ -f "$SKILL_ROOT/visual-companion.md" ]
  assert [ -f "$SKILL_ROOT/helper.sh" ]
  assert [ -f "$SKILL_ROOT/graph.dot" ]
  refute [ -e "$SKILL_ROOT/companion-dir" ]
}

@test "canonical files survive a wildcard extraFiles glob" {
  # `*` matches SKILL.md (which the awk pass then overwrites). The
  # final SKILL.md must be the normalized version.
  assert [ -f "$SKILL_ROOT/SKILL.md" ]
  run head -n 1 "$SKILL_ROOT/SKILL.md"
  assert_output "---"
  run grep -E '^name:' "$SKILL_ROOT/SKILL.md"
  assert_output "name: example-skill-extra-files"
  # references/ is still copied via the dir loop.
  assert [ -f "$SKILL_ROOT/references/note.md" ]
}
