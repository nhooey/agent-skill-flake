#!/usr/bin/env bats
# Inputs:
#   WRAPPED_SKILL_ROOT — `$out/share/claude-skills/gstack-example-skill`
#                       of the wrapped single-skill fixture.
setup() { source "$BATS_HELPERS"; }

@test "wrapped skill dir uses the prefixed name" {
  assert [ -d "$WRAPPED_SKILL_ROOT" ]
  assert_equal "$(basename "$WRAPPED_SKILL_ROOT")" "gstack-example-skill"
}

@test "SKILL.md frontmatter is rewritten to the prefixed name" {
  assert [ -f "$WRAPPED_SKILL_ROOT/SKILL.md" ]
  run grep -m1 '^name:' "$WRAPPED_SKILL_ROOT/SKILL.md"
  assert_output "name: gstack-example-skill"
}

@test "sentinel skillName matches; originalSkillName + managedBy preserved" {
  local s="$WRAPPED_SKILL_ROOT/.flake-skills-managed.json"
  assert [ -f "$s" ]
  assert_equal "$(jq -r '.skillName' "$s")" "gstack-example-skill"
  # originalSkillName is the *upstream* name (pre-prefix, pre-rename).
  # Wrapping must not stomp it — traceability back to the source repo
  # has to survive consumer-side re-prefixing.
  assert_equal "$(jq -r '.originalSkillName' "$s")" "example-skill"
  # managedBy is the original lineage. Wrapper must not claim authorship.
  assert_equal "$(jq -r '.managedBy' "$s")" "github:nhooey/flake-skills"
  assert_equal "$(jq -r '.schemaVersion' "$s")" "2"
}

@test "non-frontmatter content of the source dir survives" {
  # references/ and scripts/ from the source fixture must still be there
  # — the wrapper copies recursively before rewriting frontmatter.
  assert [ -d "$WRAPPED_SKILL_ROOT/references" ]
  assert [ -d "$WRAPPED_SKILL_ROOT/scripts" ]
}
