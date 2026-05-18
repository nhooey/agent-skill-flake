#!/usr/bin/env bats
# Inputs: ALPHA_PKG, BETA_PKG — per-skill package store paths.
setup() { source "$BATS_HELPERS"; }

@test "per-skill packages each contain only their own skill" {
  assert [ -f "$ALPHA_PKG/share/claude-skills/alpha/SKILL.md" ]
  refute [ -e "$ALPHA_PKG/share/claude-skills/beta" ]

  assert [ -f "$BETA_PKG/share/claude-skills/beta/SKILL.md" ]
  assert [ -f "$BETA_PKG/share/claude-skills/beta/references/notes.md" ]
  assert [ -f "$BETA_PKG/share/claude-skills/beta/scripts/run.sh" ]
  refute [ -e "$BETA_PKG/share/claude-skills/alpha" ]
}
