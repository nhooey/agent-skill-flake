#!/usr/bin/env bats
# Inputs: ALL_SKILLS_ROOT — share/claude-skills of the aggregate output.
setup() { source "$BATS_HELPERS"; }

@test "aggregate contains both skills, filters non-skills" {
  assert [ -f "$ALL_SKILLS_ROOT/alpha/SKILL.md" ]
  assert [ -f "$ALL_SKILLS_ROOT/beta/SKILL.md" ]
  assert [ -f "$ALL_SKILLS_ROOT/beta/references/notes.md" ]
  assert [ -f "$ALL_SKILLS_ROOT/beta/scripts/run.sh" ]

  refute [ -e "$ALL_SKILLS_ROOT/not-a-skill" ]
  refute [ -e "$ALL_SKILLS_ROOT/beta/.hidden" ]
  refute [ -e "$ALL_SKILLS_ROOT/README.md" ]
}
