#!/usr/bin/env bats
# Inputs: PREFIXED_INSTALL_APP — installer built by `lib.mkPrefixedInstaller`
# over fixtureAll with namePrefix "src". Installs the prefixed names
# end-to-end: the on-disk skill dirs, frontmatter, and sentinel all carry
# `src-<oldName>`.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "mkPrefixedInstaller installs the prefixed skill names" {
  run "$PREFIXED_INSTALL_APP" "${scope_args[@]}"
  assert_success

  assert [ -f "$CUSTOM_TARGET/src-alpha/SKILL.md" ]
  assert [ -f "$CUSTOM_TARGET/src-beta/SKILL.md" ]
  # The un-prefixed originals must not appear.
  refute [ -e "$CUSTOM_TARGET/alpha" ]
  refute [ -e "$CUSTOM_TARGET/beta" ]

  run grep -m1 '^name:' "$CUSTOM_TARGET/src-alpha/SKILL.md"
  assert_output "name: src-alpha"

  local s
  for s in src-alpha src-beta; do
    assert_store_symlink "$CUSTOM_TARGET/$s"
  done
}
