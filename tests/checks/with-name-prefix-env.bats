#!/usr/bin/env bats
# Inputs:
#   WRAPPED_ENV_ROOT — `$out/share/claude-skills` of the wrapped env.
#                      Members are the prefixed per-skill dirs.
setup() { source "$BATS_HELPERS"; }

@test "every member dir uses the prefixed name" {
  assert [ -d "$WRAPPED_ENV_ROOT/superpowers-alpha" ]
  assert [ -d "$WRAPPED_ENV_ROOT/superpowers-beta" ]
  # The original (unprefixed) names must not survive as visible dirs.
  refute [ -e "$WRAPPED_ENV_ROOT/alpha" ]
  refute [ -e "$WRAPPED_ENV_ROOT/beta" ]
}

@test "frontmatter names are rewritten per member" {
  run grep -m1 '^name:' "$WRAPPED_ENV_ROOT/superpowers-alpha/SKILL.md"
  assert_output "name: superpowers-alpha"
  run grep -m1 '^name:' "$WRAPPED_ENV_ROOT/superpowers-beta/SKILL.md"
  assert_output "name: superpowers-beta"
}

@test "sentinels carry prefixed skillName + preserved originalSkillName" {
  local a="$WRAPPED_ENV_ROOT/superpowers-alpha/.agent-skill-flake-managed.json"
  local b="$WRAPPED_ENV_ROOT/superpowers-beta/.agent-skill-flake-managed.json"
  assert_equal "$(jq -r '.skillName' "$a")" "superpowers-alpha"
  assert_equal "$(jq -r '.originalSkillName' "$a")" "alpha"
  assert_equal "$(jq -r '.skillName' "$b")" "superpowers-beta"
  assert_equal "$(jq -r '.originalSkillName' "$b")" "beta"
}
