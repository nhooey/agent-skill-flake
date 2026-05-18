#!/usr/bin/env bats
# Inputs: RECONCILE_ALL_APP — aggregate reconcile entrypoint.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CLAUDE_SKILLS_DIR"
}

@test "reconcile rewrites the lock to exactly the declared set" {
  printf '%s' \
    '{"schemaVersion":1,"skills":{"stale":{"managedBy":"github:nhooey/flake-skills","skillName":"stale"}}}' \
    > "$CLAUDE_SKILLS_DIR/.flake-skills-lock.json"

  run "$RECONCILE_ALL_APP"
  assert_success

  local lock="$CLAUDE_SKILLS_DIR/.flake-skills-lock.json"
  assert_equal "$(jq -r '.skills | keys | sort | join(",")' "$lock")" "alpha,beta"
  assert_equal "$(jq '.skills | has("stale")' "$lock")" "false"

  local s
  for s in alpha beta; do
    assert_equal "$(jq -r --arg s "$s" '.skills[$s].skillName' "$lock")" "$s"
    assert [ -n "$(jq -r --arg s "$s" '.skills[$s].storePath' "$lock")" ]
  done
}
