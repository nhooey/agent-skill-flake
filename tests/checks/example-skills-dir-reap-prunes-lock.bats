#!/usr/bin/env bats
# Inputs: REAP_ALL_APP — aggregate reap entrypoint.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CUSTOM_TARGET"
}

@test "reap drops the lock entry with the symlink + GC root" {
  # Stale lock entry: a prior install whose store path was since GC'd.
  printf '%s' \
    '{"schemaVersion":1,"skills":{"foo":{"managedBy":"github:nhooey/flake-skills","skillName":"foo"}}}' \
    > "$CUSTOM_TARGET/.flake-skills-lock.json"

  local bogus=/nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-bogus
  ln -sfn "$bogus/share/claude-skills/foo" "$CUSTOM_TARGET/foo"
  ln -sfn "$bogus" "$GCROOTS_DIR/claude-skill-foo"

  run "$REAP_ALL_APP" "${scope_args[@]}"
  assert_success

  refute [ -L "$CUSTOM_TARGET/foo" ]
  refute [ -e "$GCROOTS_DIR/claude-skill-foo" ]
  assert_equal \
    "$(jq '.skills | has("foo")' "$CUSTOM_TARGET/.flake-skills-lock.json")" \
    "false"
}
