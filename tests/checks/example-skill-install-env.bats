#!/usr/bin/env bats
# Inputs: INSTALL_APP — single-skill install entrypoint.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "install obeys CLAUDE_SKILLS_DIR, symlinks store, leaves \$HOME alone" {
  run "$INSTALL_APP"
  assert_success

  assert [ -f "$CLAUDE_SKILLS_DIR/example-skill/SKILL.md" ]
  assert [ -f "$CLAUDE_SKILLS_DIR/example-skill/references/note.md" ]
  assert [ -f "$CLAUDE_SKILLS_DIR/example-skill/scripts/run.sh" ]

  assert_store_symlink "$CLAUDE_SKILLS_DIR/example-skill"
  assert_store_symlink "$NIX_GCROOTS_DIR/claude-skill-example-skill" "GC root"

  refute [ -e "$HOME/.claude/skills/example-skill" ]
}
