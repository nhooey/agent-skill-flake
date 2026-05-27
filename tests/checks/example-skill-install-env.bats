#!/usr/bin/env bats
# Inputs: INSTALL_APP — single-skill install entrypoint.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "install with --scope=custom symlinks into the chosen root, leaves \$HOME alone" {
  run "$INSTALL_APP" "${scope_args[@]}"
  assert_success

  assert [ -f "$CUSTOM_TARGET/example-skill/SKILL.md" ]
  assert [ -f "$CUSTOM_TARGET/example-skill/references/note.md" ]
  assert [ -f "$CUSTOM_TARGET/example-skill/scripts/run.sh" ]

  assert_store_symlink "$CUSTOM_TARGET/example-skill"
  assert_store_symlink "$GCROOTS_DIR/claude-skill-example-skill" "GC root"

  refute [ -e "$HOME/.claude/skills/example-skill" ]
}
