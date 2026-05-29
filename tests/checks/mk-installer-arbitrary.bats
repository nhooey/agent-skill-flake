#!/usr/bin/env bats
# Inputs: ARBITRARY_INSTALL_APP — installer built by `lib.mkInstaller` over
# an arbitrary [{name;drv;}] set (alpha + beta lifted off fixtureAll). Proves
# the public installer primitive needs no internal.nix import and produces a
# working `bin/install-<appName>` that honours --scope.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "mkInstaller produces a working installer over an arbitrary skill set" {
  run "$ARBITRARY_INSTALL_APP" "${scope_args[@]}"
  assert_success

  assert [ -f "$CUSTOM_TARGET/alpha/SKILL.md" ]
  assert [ -f "$CUSTOM_TARGET/beta/SKILL.md" ]

  local s
  for s in alpha beta; do
    assert_store_symlink "$CUSTOM_TARGET/$s"
    assert_store_symlink "$GCROOTS_DIR/claude-skill-$s" "GC root for $s"
  done

  refute [ -e "$HOME/.claude/skills/alpha" ]
}
