#!/usr/bin/env bats
# Inputs: PURGE_SKILL_APP — single-skill purge entrypoint.
# Verifies mk-skill-flake wires a purge app; behavior is covered elsewhere.
setup() { source "$BATS_HELPERS"; }

@test "single-skill flake exposes an executable purge app" {
  assert [ -x "$PURGE_SKILL_APP" ]
}
