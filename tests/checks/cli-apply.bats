#!/usr/bin/env bats
# Inputs: CLI — the agent-skill-flake binary; STORE_FILE — a JSON file in
#         /nix/store, standing in for a Home Manager-managed target.
#
# `agent-skill-flake apply`: claude-code's trusted-dirs written into
# permissions.additionalDirectories of settings.json (only that key,
# idempotently), the post-checkout git config hook registered in the
# global git config, and both refused, with nothing changed, when the
# target is a Nix store symlink or isn't writable.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  export XDG_CONFIG_HOME="$HOME/.config"
  export GIT_CONFIG_GLOBAL="$HOME/gitconfig"
  unset CLAUDE_CONFIG_DIR
  SETTINGS="$HOME/.claude/settings.json"
  mkdir -p "$XDG_CONFIG_HOME/agent-skill-flake" "$HOME/.claude"
  cat >"$XDG_CONFIG_HOME/agent-skill-flake/config.toml" <<'EOF'
[agents.claude-code]
trusted-dirs = ["~/git", "/srv/shared", "/already"]
EOF
}

@test "apply adds trusted dirs and keeps every other key" {
  cat >"$SETTINGS" <<'EOF'
{"theme": "dark", "permissions": {"allow": ["Bash(ls)"], "additionalDirectories": ["/already"]}, "env": {"A": "1"}}
EOF
  run "$CLI" apply
  assert_success
  assert_output --partial "claude-code: trusted dirs written"

  assert_equal "$(jq -c .permissions.additionalDirectories "$SETTINGS")" \
    "[\"/already\",\"$HOME/git\",\"/srv/shared\"]"
  assert_equal "$(jq -r .theme "$SETTINGS")" "dark"
  assert_equal "$(jq -c .permissions.allow "$SETTINGS")" '["Bash(ls)"]'
  assert_equal "$(jq -c .env "$SETTINGS")" '{"A":"1"}'
}

@test "apply is idempotent" {
  run "$CLI" apply
  assert_success
  local before
  before=$(cat "$SETTINGS")

  run "$CLI" apply
  assert_success
  assert_output --partial "already lists every trusted dir"
  assert_output --partial "already registered"
  assert_equal "$(cat "$SETTINGS")" "$before"
  assert_equal "$(jq '.permissions.additionalDirectories | length' "$SETTINGS")" "3"
}

@test "apply creates settings.json, and honors CLAUDE_CONFIG_DIR" {
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude-config"
  run "$CLI" apply
  assert_success
  assert_equal "$(jq -c .permissions.additionalDirectories "$CLAUDE_CONFIG_DIR/settings.json")" \
    "[\"$HOME/git\",\"/srv/shared\",\"/already\"]"
  refute [ -e "$SETTINGS" ]
}

@test "apply writes through a symlink to a writable file" {
  echo '{"theme": "light"}' >"$BATS_TEST_TMPDIR/dotfiles-settings.json"
  ln -s "$BATS_TEST_TMPDIR/dotfiles-settings.json" "$SETTINGS"
  run "$CLI" apply
  assert_success
  assert [ -L "$SETTINGS" ]
  assert_equal "$(jq -r .theme "$BATS_TEST_TMPDIR/dotfiles-settings.json")" "light"
  assert_equal "$(jq '.permissions.additionalDirectories | length' "$BATS_TEST_TMPDIR/dotfiles-settings.json")" "3"
}

@test "apply refuses a read-only settings.json, prints the JSON, and exits non-zero" {
  echo '{"theme": "dark"}' >"$SETTINGS"
  chmod 444 "$SETTINGS"
  run "$CLI" apply
  assert_failure
  assert_output --partial "is not writable"
  assert_output --partial '"additionalDirectories"'
  assert_output --partial "$HOME/git"
  assert_equal "$(cat "$SETTINGS")" '{"theme": "dark"}'
  # The other writer still ran.
  assert_equal "$(git config --global hook.agent-skill-flake-sync.event)" "post-checkout"
}

@test "apply refuses a settings.json symlinked into /nix/store" {
  ln -s "$STORE_FILE" "$SETTINGS"
  run "$CLI" apply
  assert_failure
  assert_output --partial "resolves into the Nix store"
  assert_output --partial '"additionalDirectories"'
  assert_equal "$(readlink "$SETTINGS")" "$STORE_FILE"
}

@test "apply registers the post-checkout git config hook, idempotently" {
  git config --global user.name "Kept Name"
  run "$CLI" apply
  assert_success
  assert_output --partial "git: registered the agent-skill-flake-sync hook"
  assert_equal "$(git config --global --get-all hook.agent-skill-flake-sync.event)" "post-checkout"
  assert_equal "$(git config --global hook.agent-skill-flake-sync.command)" \
    "agent-skill-flake sync-project --from-hook"
  assert_equal "$(git config --global user.name)" "Kept Name"
  run git config --global core.hooksPath
  assert_failure

  local before
  before=$(cat "$GIT_CONFIG_GLOBAL")
  run "$CLI" apply
  assert_success
  assert_equal "$(cat "$GIT_CONFIG_GLOBAL")" "$before"
}

@test "apply fixes a stale hook registration" {
  git config --global --add hook.agent-skill-flake-sync.event post-checkout
  git config --global --add hook.agent-skill-flake-sync.event pre-commit
  git config --global hook.agent-skill-flake-sync.command "old-command"
  run "$CLI" apply
  assert_success
  assert_equal "$(git config --global --get-all hook.agent-skill-flake-sync.event)" "post-checkout"
  assert_equal "$(git config --global hook.agent-skill-flake-sync.command)" \
    "agent-skill-flake sync-project --from-hook"
}

@test "apply refuses a read-only global git config and prints the lines to add" {
  printf '[user]\n\tname = x\n' >"$GIT_CONFIG_GLOBAL"
  chmod 444 "$GIT_CONFIG_GLOBAL"
  run "$CLI" apply
  assert_failure
  assert_output --partial "git: not writing $GIT_CONFIG_GLOBAL"
  assert_output --partial '[hook "agent-skill-flake-sync"]'
  assert_output --partial "event = post-checkout"
  assert_output --partial "command = agent-skill-flake sync-project --from-hook"
  assert_equal "$(cat "$GIT_CONFIG_GLOBAL")" "$(printf '[user]\n\tname = x')"
}

@test "apply refuses a global git config symlinked into /nix/store" {
  ln -s "$STORE_FILE" "$GIT_CONFIG_GLOBAL"
  run "$CLI" apply
  assert_failure
  assert_output --partial "resolves into the Nix store"
  assert_output --partial '[hook "agent-skill-flake-sync"]'
  assert_equal "$(readlink "$GIT_CONFIG_GLOBAL")" "$STORE_FILE"
}

@test "apply with no config file still registers the hook" {
  rm "$XDG_CONFIG_HOME/agent-skill-flake/config.toml"
  run "$CLI" apply
  assert_success
  assert_output --partial "no config at"
  assert_equal "$(git config --global hook.agent-skill-flake-sync.event)" "post-checkout"
  refute [ -e "$SETTINGS" ]
}

@test "apply skips an agent with no writer yet" {
  cat >>"$XDG_CONFIG_HOME/agent-skill-flake/config.toml" <<'EOF'
[agents.some-other-agent]
trusted-dirs = ["/x"]
EOF
  run "$CLI" apply
  assert_success
  assert_output --partial "some-other-agent: skipped; no writer for this agent yet"
}
