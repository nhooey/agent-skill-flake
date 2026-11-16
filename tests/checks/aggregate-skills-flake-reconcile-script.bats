#!/usr/bin/env bats
# Inputs: RECONCILE_SCRIPT — the aggregate's `reconcileScript system`, the
# one-line command a dev-shell startup hook runs.
# Run from inside a git checkout, it reconciles the aggregate's whole union
# into the .agents/skills at that checkout's root.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  export PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/sub"
  git -C "$PROJ" init -q -b main
}

@test "reconcileScript installs the union into the project it runs in" {
  # A single command: a startup hook splices it in as one line.
  refute [ "$(printf '%s' "$RECONCILE_SCRIPT" | wc -l)" -gt 0 ]

  run bash -c "cd \"\$1\" && $RECONCILE_SCRIPT --gcroots-dir=\"\$2\"" _ "$PROJ/sub" "$GCROOTS_DIR"
  assert_success

  local name
  for name in alpha beta gamma src-alpha src-beta; do
    assert_store_symlink "$PROJ/.agents/skills/$name"
    assert [ -f "$PROJ/.agents/skills/$name/SKILL.md" ]
  done
  refute [ -e "$PROJ/sub/.agents" ]
}
