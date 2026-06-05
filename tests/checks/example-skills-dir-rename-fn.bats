#!/usr/bin/env bats
# Inputs:
#   RENAMED_ALPHA_PKG  — per-skill package for the renamed `alpha`.
#   RENAMED_ALPHA_NAME — expected derived name
#                        ("nhooey-alpha-0123456-20240424").
setup() { source "$BATS_HELPERS"; }

@test "renameFn output becomes the store dir; original name is gone" {
  local root="$RENAMED_ALPHA_PKG/share/claude-skills"
  assert [ -d "$root/$RENAMED_ALPHA_NAME" ]
  assert [ -f "$root/$RENAMED_ALPHA_NAME/SKILL.md" ]
  refute [ -e "$root/alpha" ]
}

@test "frontmatter name matches the renamed identity" {
  run grep -m1 '^name:' \
    "$RENAMED_ALPHA_PKG/share/claude-skills/$RENAMED_ALPHA_NAME/SKILL.md"
  assert_output "name: $RENAMED_ALPHA_NAME"
}

@test "sentinel records renamed name + original name as provenance" {
  local s="$RENAMED_ALPHA_PKG/share/claude-skills/$RENAMED_ALPHA_NAME/.agent-skill-flake-managed.json"
  assert [ -f "$s" ]
  assert_equal "$(jq -r '.skillName' "$s")" "$RENAMED_ALPHA_NAME"
  assert_equal "$(jq -r '.originalSkillName' "$s")" "alpha"
  assert_equal "$(jq -r '.schemaVersion' "$s")" "2"
}
