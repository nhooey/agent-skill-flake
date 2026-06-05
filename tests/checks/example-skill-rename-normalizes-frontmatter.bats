#!/usr/bin/env bats
# Inputs: RENAME_SKILL_ROOT — install root of the fixture whose SKILL.md
# frontmatter `name:` ("divergent-upstream-name") differs from the
# skillName passed to mkSkillFlake ("example-skill-renamed").
setup() { source "$BATS_HELPERS"; }

@test "installed frontmatter name is normalized to the canonical name" {
  assert [ -f "$RENAME_SKILL_ROOT/SKILL.md" ]

  # The first (top-level) frontmatter `name:` is rewritten.
  run grep -m1 '^name:' "$RENAME_SKILL_ROOT/SKILL.md"
  assert_output "name: example-skill-renamed"

  # The upstream divergent value must not survive as the name.
  refute_output --partial "divergent-upstream-name"
}

@test "only the frontmatter was touched; body is preserved" {
  # The body heading still carries the original text — proof we rewrote
  # the frontmatter block only, not every line matching the old name.
  assert grep -q '^# divergent-upstream-name' "$RENAME_SKILL_ROOT/SKILL.md"
}

@test "store dir + sentinel agree on the canonical name" {
  assert_equal "$(basename "$RENAME_SKILL_ROOT")" "example-skill-renamed"

  local s="$RENAME_SKILL_ROOT/.agent-skill-flake-managed.json"
  assert [ -f "$s" ]
  assert_equal "$(jq -r '.skillName' "$s")" "example-skill-renamed"
  assert_equal "$(jq -r '.schemaVersion' "$s")" "2"
  assert_equal "$(jq -r 'has("originalSkillName")' "$s")" "true"
}
