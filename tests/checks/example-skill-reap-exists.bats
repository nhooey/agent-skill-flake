#!/usr/bin/env bats
# Inputs: REAP_SKILL_APP — single-skill reap entrypoint.
# Verifies mk-skill-flake wires a reap app; behavior is covered elsewhere.
setup() { source "$BATS_HELPERS"; }

@test "single-skill flake exposes an executable reap app" {
  assert [ -x "$REAP_SKILL_APP" ]
}
