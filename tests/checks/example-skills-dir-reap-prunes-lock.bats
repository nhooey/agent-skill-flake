#!/usr/bin/env bats
# Inputs: REAP_ALL_APP — aggregate reap entrypoint.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CLAUDE_SKILLS_DIR"
}

@test "reap drops the lock entry with the symlink + GC root" {
  # Stale lock entry: a prior install whose store path was since GC'd.
  printf '%s' \
    '{"schemaVersion":1,"skills":{"foo":{"managedBy":"github:nhooey/flake-skills","skillName":"foo"}}}' \
    > "$CLAUDE_SKILLS_DIR/.flake-skills-lock.json"

  local bogus=/nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-bogus
  ln -sfn "$bogus/share/claude-skills/foo" "$CLAUDE_SKILLS_DIR/foo"
  ln -sfn "$bogus" "$NIX_GCROOTS_DIR/claude-skill-foo"

  run "$REAP_ALL_APP"
  assert_success

  refute [ -L "$CLAUDE_SKILLS_DIR/foo" ]
  refute [ -e "$NIX_GCROOTS_DIR/claude-skill-foo" ]
  assert_equal \
    "$(jq '.skills | has("foo")' "$CLAUDE_SKILLS_DIR/.flake-skills-lock.json")" \
    "false"
}
