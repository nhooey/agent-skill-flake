#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP — aggregate install entrypoint.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "aggregate install: one symlink + GC root per skill, \$HOME alone" {
  run "$INSTALL_ALL_APP" "${scope_args[@]}"
  assert_success

  assert [ -f "$CUSTOM_TARGET/alpha/SKILL.md" ]
  assert [ -f "$CUSTOM_TARGET/beta/SKILL.md" ]
  assert [ -f "$CUSTOM_TARGET/beta/references/notes.md" ]

  local s
  for s in alpha beta; do
    assert_store_symlink "$CUSTOM_TARGET/$s"
    assert_store_symlink "$GCROOTS_DIR/claude-skill-$s" "GC root for $s"
  done

  refute [ -e "$HOME/.claude/skills/alpha" ]
  refute [ -e "$HOME/.claude/skills/beta" ]
}
