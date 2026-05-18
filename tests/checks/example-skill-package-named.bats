#!/usr/bin/env bats
# Inputs: SKILL_PKG_ROOT — share/claude-skills/example-skill from the
# `skill-<name>` (prefixed) package. Forces eval of the renamed attribute.
setup() { source "$BATS_HELPERS"; }

@test "skill-<name> package exposes SKILL.md" {
  assert [ -f "$SKILL_PKG_ROOT/SKILL.md" ]
}
