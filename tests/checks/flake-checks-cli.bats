#!/usr/bin/env bats
# Inputs: FLAKE_CHECKS — the dev shell's `flake-checks` tool.
#
# Argument parsing and the nix command lines `flake-checks` builds, read
# through --dry-run with --flake and --system given so nothing calls nix.
setup() {
  source "$BATS_HELPERS"
}

@test "--help lists every command and option" {
  run "$FLAKE_CHECKS" --help
  assert_success
  for token in list run all help --flake --system --dry-run; do
    assert_output --partial "$token"
  done
}

@test "help as a command prints the usage" {
  run "$FLAKE_CHECKS" help
  assert_success
  assert_line --index 0 --partial "Usage: flake-checks"
}

@test "no command is a usage error" {
  run "$FLAKE_CHECKS"
  assert_failure 2
  assert_output --partial "no command given"
}

@test "an unknown command is a usage error" {
  run "$FLAKE_CHECKS" frobnicate
  assert_failure 2
  assert_output --partial "unknown command: frobnicate"
}

@test "an unknown option is a usage error" {
  run "$FLAKE_CHECKS" list --verbose
  assert_failure 2
  assert_output --partial "unknown option: --verbose"
}

@test "--flake with no value is a usage error" {
  run "$FLAKE_CHECKS" list --flake
  assert_failure 2
  assert_output --partial "--flake needs a value"
}

@test "run with no names is a usage error" {
  run "$FLAKE_CHECKS" run --flake /repo --system x86_64-linux
  assert_failure 2
  assert_output --partial "run needs at least one check name"
}

@test "run refuses a name that isn't a bare attribute" {
  run "$FLAKE_CHECKS" run --flake /repo --system x86_64-linux 'a.b'
  assert_failure 2
  assert_output --partial "not a check name: a.b"
}

@test "list and all take no names" {
  run "$FLAKE_CHECKS" list --flake /repo --system x86_64-linux extra
  assert_failure 2
  run "$FLAKE_CHECKS" all --flake /repo extra
  assert_failure 2
}

@test "run builds one installable per name with logs" {
  run "$FLAKE_CHECKS" run --dry-run --flake /repo --system=aarch64-darwin \
    cli-apply init-scaffolds
  assert_success
  assert_output "nix build --no-link -L /repo#checks.aarch64-darwin.cli-apply /repo#checks.aarch64-darwin.init-scaffolds"
}

@test "options may follow the names" {
  run "$FLAKE_CHECKS" run cli-apply --flake=/repo --system x86_64-linux --dry-run
  assert_success
  assert_output "nix build --no-link -L /repo#checks.x86_64-linux.cli-apply"
}

@test "list evaluates the system's check names" {
  run "$FLAKE_CHECKS" list --dry-run --flake /repo --system x86_64-linux
  assert_success
  assert_output --partial "nix eval --raw /repo#checks.x86_64-linux --apply"
}

@test "all runs nix flake check on the flake" {
  run "$FLAKE_CHECKS" all --dry-run --flake /repo
  assert_success
  assert_output "nix flake check -L /repo"
  run "$FLAKE_CHECKS" all --dry-run --flake /repo --system x86_64-linux
  assert_output "nix flake check -L /repo --system x86_64-linux"
}

@test "the flake defaults to the git top level" {
  git init -q "$BATS_TEST_TMPDIR/repo"
  mkdir "$BATS_TEST_TMPDIR/repo/sub"
  cd "$BATS_TEST_TMPDIR/repo/sub"
  run "$FLAKE_CHECKS" all --dry-run
  assert_success
  assert_output "nix flake check -L $(cd "$BATS_TEST_TMPDIR/repo" && pwd -P)"
}
