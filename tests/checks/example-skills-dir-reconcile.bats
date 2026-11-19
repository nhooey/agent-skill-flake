#!/usr/bin/env bats
# Inputs: ALPHA_PKG, RECONCILE_ALL_APP.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  mkdir -p "$CUSTOM_TARGET"
}

@test "reconcile installs declared set, sweeps stray, spares unmanaged" {
  # Stray managed entry: reuse alpha's content (sentinel genuinely
  # matches our managedBy URL) under a name not in the declared set.
  ln -sfn "$ALPHA_PKG/share/claude-skills/alpha" "$CUSTOM_TARGET/stale"
  fake_gc_record stale "$ALPHA_PKG"

  mkdir -p "$CUSTOM_TARGET/manual-skill"
  echo manual > "$CUSTOM_TARGET/manual-skill/SKILL.md"

  run "$RECONCILE_ALL_APP" "${scope_args[@]}"
  assert_success

  assert [ -L "$CUSTOM_TARGET/alpha" ]
  assert [ -L "$CUSTOM_TARGET/beta" ]
  assert [ -f "$CUSTOM_TARGET/alpha/SKILL.md" ]
  assert [ -f "$CUSTOM_TARGET/beta/SKILL.md" ]
  assert_gc_rooted alpha
  assert_gc_rooted beta

  # The stray's record goes; the root it shared with alpha stays.
  refute [ -L "$CUSTOM_TARGET/stale" ]
  refute [ -e "$(gc_record stale)" ]
  assert_equal "$(readlink "$(gc_shared_root "$ALPHA_PKG")")" "$ALPHA_PKG"

  assert [ -d "$CUSTOM_TARGET/manual-skill" ]
  assert [ -f "$CUSTOM_TARGET/manual-skill/SKILL.md" ]
}
