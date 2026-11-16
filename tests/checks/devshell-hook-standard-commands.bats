#!/usr/bin/env bats
# Inputs: STANDARD_COMMANDS — devshellSkillsHook's standardCommands as JSON.
# Runs each command's text against a stub `nix` that records its argv, so
# the test pins which nix subcommand each runs and that the command's own
# arguments reach it intact, without restating the help text.
setup() {
  source "$BATS_HELPERS"
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat >"$bin/nix" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@"
STUB
  chmod +x "$bin/nix"
  export PATH="$bin:$PATH"
}

# run_command <name> <args...> — runs the named command's text as devshell
# does: a bash script whose positional parameters are the command's args.
run_command() {
  local name=$1 text
  shift
  text=$(jq -er --arg n "$name" '.[] | select(.name == $n) | .command' "$STANDARD_COMMANDS")
  run bash -c "$text" "$name" "$@"
}

@test "exactly check, fmt and update-flake, in the ci/dev/maintenance categories" {
  assert_equal \
    "$(jq -r '[.[] | "\(.category)/\(.name)"] | join(" ")' "$STANDARD_COMMANDS")" \
    "ci/check dev/fmt maintenance/update-flake"
  assert_equal "$(jq '[.[] | select((.help | length) == 0)] | length' "$STANDARD_COMMANDS")" "0"
}

@test "check runs nix flake check with the caller's args" {
  run_command check --keep-going 'a b'
  assert_success
  assert_equal "$output" "$(printf '%s\n' flake check --keep-going 'a b')"
}

@test "fmt runs nix fmt with the caller's args" {
  run_command fmt README.md
  assert_success
  assert_equal "$output" "$(printf '%s\n' fmt README.md)"
}

@test "update-flake runs nix flake update with the caller's args" {
  run_command update-flake nixpkgs
  assert_success
  assert_equal "$output" "$(printf '%s\n' flake update nixpkgs)"
}
