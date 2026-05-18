#!/usr/bin/env bats
# Inputs: ALPHA_PKG, RECONCILE_ALL_APP.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CLAUDE_SKILLS_DIR"
}

@test "reconcile installs declared set, sweeps stray, spares unmanaged" {
  # Stray managed entry: reuse alpha's content (sentinel genuinely
  # matches our managedBy URL) under a name not in the declared set.
  ln -sfn "$ALPHA_PKG/share/claude-skills/alpha" "$CLAUDE_SKILLS_DIR/stale"
  ln -sfn "$ALPHA_PKG" "$NIX_GCROOTS_DIR/claude-skill-stale"

  mkdir -p "$CLAUDE_SKILLS_DIR/manual-skill"
  echo manual > "$CLAUDE_SKILLS_DIR/manual-skill/SKILL.md"

  run "$RECONCILE_ALL_APP"
  assert_success

  assert [ -L "$CLAUDE_SKILLS_DIR/alpha" ]
  assert [ -L "$CLAUDE_SKILLS_DIR/beta" ]
  assert [ -f "$CLAUDE_SKILLS_DIR/alpha/SKILL.md" ]
  assert [ -f "$CLAUDE_SKILLS_DIR/beta/SKILL.md" ]
  assert [ -L "$NIX_GCROOTS_DIR/claude-skill-alpha" ]
  assert [ -L "$NIX_GCROOTS_DIR/claude-skill-beta" ]

  refute [ -L "$CLAUDE_SKILLS_DIR/stale" ]
  refute [ -e "$NIX_GCROOTS_DIR/claude-skill-stale" ]

  assert [ -d "$CLAUDE_SKILLS_DIR/manual-skill" ]
  assert [ -f "$CLAUDE_SKILLS_DIR/manual-skill/SKILL.md" ]
}
