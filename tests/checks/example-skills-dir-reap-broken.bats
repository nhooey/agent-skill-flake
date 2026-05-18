#!/usr/bin/env bats
# Inputs: REAP_ALL_APP — aggregate reap entrypoint.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CLAUDE_SKILLS_DIR"
}

@test "reap removes managed-but-broken entry, spares unmanaged" {
  # Forge a managed-but-broken entry: symlink to a non-existent store
  # path + same-named GC root (the naming-convention fallback).
  local bogus=/nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-bogus
  ln -sfn "$bogus/share/claude-skills/foo" "$CLAUDE_SKILLS_DIR/foo"
  ln -sfn "$bogus" "$NIX_GCROOTS_DIR/claude-skill-foo"

  # Unmanaged entry — must NOT be touched.
  mkdir -p "$CLAUDE_SKILLS_DIR/manual-skill"
  echo manual > "$CLAUDE_SKILLS_DIR/manual-skill/SKILL.md"

  run "$REAP_ALL_APP"
  assert_success

  refute [ -L "$CLAUDE_SKILLS_DIR/foo" ]
  refute [ -e "$NIX_GCROOTS_DIR/claude-skill-foo" ]

  assert [ -d "$CLAUDE_SKILLS_DIR/manual-skill" ]
  assert [ -f "$CLAUDE_SKILLS_DIR/manual-skill/SKILL.md" ]
}
