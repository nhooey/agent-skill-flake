#!/usr/bin/env bats
# Inputs: SKILL_ROOT — the example-skill output under share/claude-skills.
setup() { source "$BATS_HELPERS"; }

@test "required files present, plumbing/hidden absent" {
  assert [ -f "$SKILL_ROOT/SKILL.md" ]
  assert [ -f "$SKILL_ROOT/references/note.md" ]
  assert [ -f "$SKILL_ROOT/scripts/run.sh" ]
  refute [ -e "$SKILL_ROOT/flake.nix" ]
  refute [ -e "$SKILL_ROOT/.hidden" ]
}

@test "sentinel has all required fields and sane values" {
  local sentinel="$SKILL_ROOT/.agent-skill-flake-managed.json"
  assert [ -f "$sentinel" ]

  local field
  for field in schemaVersion managedBy managedByRev managedByDirty \
               managedByNarHash skillName originalSkillName version; do
    assert_equal "$(jq -r --arg f "$field" 'has($f)' "$sentinel")" "true"
  done

  assert_equal "$(jq -r '.skillName' "$sentinel")" "example-skill"
  # No rename for this fixture, so originalSkillName == skillName.
  assert_equal "$(jq -r '.originalSkillName' "$sentinel")" "example-skill"
  assert_equal "$(jq -r '.schemaVersion' "$sentinel")" "2"

  # managedByRev must be a clean SHA (no `-dirty` suffix).
  local rev
  rev=$(jq -r '.managedByRev' "$sentinel")
  refute [ "${rev%-dirty}" != "$rev" ]
}
