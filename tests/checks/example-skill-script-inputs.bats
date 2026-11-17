#!/usr/bin/env bats
# Inputs: SKILL_ROOT — install root of a build with
#           scriptInputs = pkgs: [ pkgs.hello ]
#         ALL_SKILLS_ROOT — share/claude-skills of a mkAllSkillsFlake
#           build with scriptInputs.beta = pkgs: [ pkgs.hello ]
setup() { source "$BATS_HELPERS"; }

@test "a wrapped script finds its scriptInputs with an empty PATH" {
  run env -i PATH=/var/empty "$SKILL_ROOT/scripts/greet.sh"
  assert_success
  assert_output "greet.sh found hello"
}

@test "a shell script keeps its path and runs under bash" {
  run env -i PATH=/var/empty "$BASH" "$SKILL_ROOT/scripts/greet.sh"
  assert_success
  assert_output "greet.sh found hello"
  refute [ -e "$SKILL_ROOT/scripts/.greet.sh-wrapped" ]
  run sed -n 2p "$SKILL_ROOT/scripts/greet.sh"
  assert_output --regexp '^PATH=/nix/store/[^:]*-hello-[^:]*/bin\$\{PATH:\+:\$PATH\}; export PATH$'
}

@test "a shell script runs under macOS's bash 3.2" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  run env -i PATH=/var/empty /bin/bash "$SKILL_ROOT/scripts/greet.sh"
  assert_success
  assert_output "greet.sh found hello"
}

@test "a file that isn't executable is shipped as it is" {
  assert [ -f "$SKILL_ROOT/scripts/data.txt" ]
  refute [ -e "$SKILL_ROOT/scripts/.data.txt-wrapped" ]
  run cat "$SKILL_ROOT/scripts/data.txt"
  assert_output --partial "leaves it unwrapped"
}

@test "mkAllSkillsFlake gives scriptInputs only to the skills it names" {
  run grep --fixed-strings --quiet "hello" "$ALL_SKILLS_ROOT/beta/scripts/run.sh"
  assert_success
  refute [ -e "$ALL_SKILLS_ROOT/alpha/scripts" ]
}
