#!/usr/bin/env bats
# Inputs: INSTALL_CODEX_APP — a build of the single-skill fixture with
#         `agent = "codex"`.
#
# Building with `agent = "codex"` selects the codex profile from
# lib/agent-profiles.nix, whose personalSuffix is `.codex/skills`. So
# `--scope=personal` must land under $HOME/.codex/skills/, not
# $HOME/.claude/skills/.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

@test "agent=codex installs under \$HOME/.codex/skills/, not .claude/skills/" {
  run "$INSTALL_CODEX_APP" --scope=personal --gcroots-dir="$GCROOTS_DIR"
  assert_success

  assert [ -L "$HOME/.codex/skills/example-skill" ]
  assert_store_symlink "$HOME/.codex/skills/example-skill"
  refute [ -e "$HOME/.claude/skills/example-skill" ]
}
