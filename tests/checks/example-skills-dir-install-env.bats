#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP — aggregate install entrypoint.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "aggregate install: one symlink + GC root per skill, \$HOME alone" {
  run "$INSTALL_ALL_APP"
  assert_success

  assert [ -f "$CLAUDE_SKILLS_DIR/alpha/SKILL.md" ]
  assert [ -f "$CLAUDE_SKILLS_DIR/beta/SKILL.md" ]
  assert [ -f "$CLAUDE_SKILLS_DIR/beta/references/notes.md" ]

  local s
  for s in alpha beta; do
    assert_store_symlink "$CLAUDE_SKILLS_DIR/$s"
    assert_store_symlink "$NIX_GCROOTS_DIR/claude-skill-$s" "GC root for $s"
  done

  refute [ -e "$HOME/.claude/skills/alpha" ]
  refute [ -e "$HOME/.claude/skills/beta" ]
}
