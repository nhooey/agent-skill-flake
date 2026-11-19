#!/usr/bin/env bats
# Inputs: RECONCILE_APP          — a reconcile declaring alpha and beta.
#         ALPHA_PKG, BETA_PKG    — the alpha and beta it installs.
#         BETA_OTHER_PKG         — beta built from the same source with other
#                                  scriptInputs: another version of beta.
#         ALPHA_RELEASED_PKG,
#         BETA_RELEASED_PKG      — alpha and beta built at version 9.9.9:
#                                  other store paths, the same content.
#         PREFIXED_RECONCILE_APP — a reconcile declaring px-alpha, the
#                                  withNamePrefix wrap of ALPHA_PKG.
#         PX_ALPHA_PKG,
#         PX_ALPHA_RELEASED_PKG  — that wrap of ALPHA_PKG and of
#                                  ALPHA_RELEASED_PKG.
#         DEVSHELL_RECONCILE_APP — mkDevshellSkillsFlake's reconcile over
#                                  alpha and beta.
# A --scope=project reconcile compares each declared skill with the copy of
# that name in the personal scope, $HOME/.claude/skills here.
bats_require_minimum_version 1.5.0

setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  unset AGENT_SKILL_FLAKE_PERSONAL_DIR AGENT_SKILL_FLAKE_PERSONAL_UPDATE_COMMAND \
    AGENT_SKILL_FLAKE_PROJECT_UPDATE_COMMAND
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  PROJ=$(cd "$BATS_TEST_TMPDIR/proj" && pwd -P)
  git -C "$PROJ" init -q -b main
  cd "$PROJ"
  skills="$PROJ/.agents/skills"
  lock="$skills/.agent-skill-flake-lock.json"
  exclude="$PROJ/.git/info/exclude"
  personal="$HOME/.claude/skills"
  alpha_src="$ALPHA_PKG/share/claude-skills/alpha"
  beta_src="$BETA_PKG/share/claude-skills/beta"
  beta_other_src="$BETA_OTHER_PKG/share/claude-skills/beta"
}

reconcile() {
  run --separate-stderr "$RECONCILE_APP" --scope=project --gcroots-dir="$GCROOTS_DIR" "$@"
}

# copy_as_older_build <skill-dir> <dest> — a writable copy of <skill-dir>
# whose sentinel says another agent-skill-flake revision built it and
# records no contentHash, as a copy installed by an older one does.
copy_as_older_build() {
  mkdir -p "$(dirname "$2")"
  cp -r "$1" "$2"
  chmod -R u+w "$2"
  jq '.managedByRev = "0000000000000000000000000000000000000000" | del(.contentHash)' \
    "$1/.agent-skill-flake-managed.json" >"$2/.agent-skill-flake-managed.json"
}

content_hash() {
  jq -r .contentHash "$1/.agent-skill-flake-managed.json"
}

# short <hash> — the form the warning prints: `sha256:` and 12 hex digits.
short() {
  local hex=${1##*:}
  printf 'sha256:%s' "${hex:0:12}"
}

# assert_same_content_elsewhere <skill-dir> <other-skill-dir> — the two are
# different store paths recording the same contentHash.
assert_same_content_elsewhere() {
  refute [ "$(realpath "$1")" = "$(realpath "$2")" ]
  assert_regex "$(content_hash "$1")" '^v1:sha256:[0-9a-f]{64}$'
  assert_equal "$(content_hash "$1")" "$(content_hash "$2")"
}

@test "a skill the personal scope holds at the same version is left to it and recorded" {
  reconcile
  assert_success
  assert_store_symlink "$skills/alpha"

  # alpha: an older build's copy, compared by hashing both folders.
  # beta: a build at another version and store path, compared by the
  # recorded contentHash.
  local beta_released="$BETA_RELEASED_PKG/share/claude-skills/beta"
  assert_same_content_elsewhere "$beta_src" "$beta_released"
  copy_as_older_build "$alpha_src" "$personal/alpha"
  ln -s "$beta_released" "$personal/beta"

  reconcile
  assert_success
  assert_equal "$stderr" ""
  assert_output --partial "reconciled (left to the personal scope's copy, $personal/alpha): $skills/alpha"
  assert_output --partial "reconciled (left to the personal scope's copy, $personal/beta): $skills/beta"
  assert_output --partial "2 declared skill(s) left to the same version in $personal."
  refute [ -e "$skills/alpha" ]
  refute [ -L "$skills/alpha" ]
  refute [ -L "$skills/beta" ]
  refute [ -e "$(gc_record alpha "$skills")" ]
  refute [ -e "$(gc_record beta "$skills")" ]
  assert_equal "$(jq -r '.skills | has("alpha") or has("beta")' "$lock")" "false"
  assert_equal "$(jq -r '.satisfiedByPersonalScope.alpha.personalCopy' "$lock")" "$personal/alpha"
  assert_equal "$(jq -r '.satisfiedByPersonalScope.alpha.installedBy' "$lock")" "example-skills-dir"
  assert_equal "$(jq -r '.satisfiedByPersonalScope.beta.contentHash' "$lock")" "$(content_hash "$beta_src")"
  run grep -Fx -e /.agents/skills/alpha -e /.agents/skills/beta "$exclude"
  assert_failure

  # Nothing to change on the next run.
  reconcile
  assert_success
  refute_output --partial "reconciled ("
}

@test "withNamePrefix wraps of the same content at other store paths are the same version" {
  local ours="$PX_ALPHA_PKG/share/claude-skills/px-alpha"
  local theirs="$PX_ALPHA_RELEASED_PKG/share/claude-skills/px-alpha"
  assert_same_content_elsewhere "$ours" "$theirs"
  refute [ "$(content_hash "$ours")" = "$(content_hash "$alpha_src")" ]
  mkdir -p "$personal"
  ln -s "$theirs" "$personal/px-alpha"

  run --separate-stderr "$PREFIXED_RECONCILE_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  assert_equal "$stderr" ""
  assert_output --partial "1 declared skill(s) left to the same version in $personal."
  refute [ -L "$skills/px-alpha" ]
  assert_equal "$(jq -r '.satisfiedByPersonalScope["px-alpha"].installedBy' "$lock")" "px"
}

@test "a skill the personal scope holds at another version is installed too, with one warning line" {
  mkdir -p "$personal"
  ln -s "$beta_other_src" "$personal/beta"
  export AGENT_SKILL_FLAKE_PERSONAL_UPDATE_COMMAND=update-my-home
  local ours theirs
  ours=$(short "$(content_hash "$beta_src")")
  theirs=$(short "$(content_hash "$beta_other_src")")
  refute [ "$ours" = "$theirs" ]

  reconcile
  assert_success
  assert_equal "$(readlink "$skills/beta")" "$beta_src"
  assert_store_symlink "$skills/alpha"
  assert_equal "${#stderr_lines[@]}" 1
  assert_equal "$stderr" "WARNING: beta is $theirs in the personal scope ($personal/beta) and $ours in this project; both are installed. Claude Code uses the personal copy. To update both to the latest: for the personal copy, run \`update-my-home\`; for the project's, run \`nix flake update --flake $PROJ\`."
  assert_equal "$(jq -r 'has("satisfiedByPersonalScope")' "$lock")" "false"
}

@test "mkDevshellSkillsFlake's reconcile names update-skills-devshell, unless the variable says otherwise" {
  mkdir -p "$personal"
  ln -s "$beta_other_src" "$personal/beta"

  run --separate-stderr "$DEVSHELL_RECONCILE_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  assert_equal "${#stderr_lines[@]}" 1
  assert_regex "$stderr" "for the project's, run \`update-skills-devshell\`\\.$"

  export AGENT_SKILL_FLAKE_PROJECT_UPDATE_COMMAND='make bump'
  run --separate-stderr "$DEVSHELL_RECONCILE_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  assert_regex "$stderr" "for the project's, run \`make bump\`\\.$"
}

@test "the project's copy comes back once the personal copy is gone, or changes" {
  copy_as_older_build "$alpha_src" "$personal/alpha"
  reconcile
  assert_success
  refute [ -L "$skills/alpha" ]

  rm -r "$personal/alpha"
  reconcile
  assert_success
  assert_equal "$stderr" ""
  assert_output --partial "reconciled (install): $skills/alpha"
  assert_store_symlink "$skills/alpha"
  assert_equal "$(jq -r '.skills | has("alpha")' "$lock")" "true"
  assert_equal "$(jq -r 'has("satisfiedByPersonalScope")' "$lock")" "false"
  run grep -Fx /.agents/skills/alpha "$exclude"
  assert_success

  copy_as_older_build "$alpha_src" "$personal/alpha"
  reconcile
  assert_success
  refute [ -L "$skills/alpha" ]

  printf 'A local edit.\n' >>"$personal/alpha/SKILL.md"
  reconcile
  assert_success
  assert_output --partial "reconciled (install): $skills/alpha"
  assert_store_symlink "$skills/alpha"
  assert_equal "${#stderr_lines[@]}" 1
  assert_regex "$stderr" "^WARNING: alpha is sha256:[0-9a-f]{12} in the personal scope \\($personal/alpha\\) and sha256:[0-9a-f]{12} in this project"
  assert_equal "$(jq -r 'has("satisfiedByPersonalScope")' "$lock")" "false"
}

@test "a personal entry that links into the project's own skills is not a personal copy" {
  reconcile
  assert_success
  mkdir -p "$personal"
  ln -s "$skills/alpha" "$personal/alpha"

  local run_number
  for run_number in 1 2; do
    reconcile
    assert_success
    assert_equal "$stderr" ""
    refute_output --partial "left to"
    refute_output --partial "reconciled ("
    assert_store_symlink "$skills/alpha"
    assert_equal "$(jq -r 'has("satisfiedByPersonalScope")' "$lock")" "false"
  done
}

@test "leaving a skill to the personal scope removes its GC root even with the link gone" {
  reconcile
  assert_success
  rm "$skills/alpha"
  assert_gc_rooted alpha "$skills"
  copy_as_older_build "$alpha_src" "$personal/alpha"

  reconcile
  assert_success
  refute [ -e "$(gc_record alpha "$skills")" ]
  refute [ -L "$(gc_record alpha "$skills")" ]
  assert_equal "$(jq -r '.satisfiedByPersonalScope | has("alpha")' "$lock")" "true"
}

@test "a personal copy that can't be read is reported in one line and the project's installed" {
  [ "$(id -u)" != 0 ] || skip "root reads any file"
  copy_as_older_build "$alpha_src" "$personal/alpha"
  chmod 000 "$personal/alpha/SKILL.md"

  reconcile
  assert_success
  assert_store_symlink "$skills/alpha"
  assert_equal "$stderr" "WARNING: $personal/alpha could not be read to compare it with this project's alpha; installing the project's copy."
  assert_equal "$(jq -r 'has("satisfiedByPersonalScope")' "$lock")" "false"
}

@test "with no personal scope, or no copy of a skill there, the reconcile is as before" {
  reconcile
  assert_success
  assert_equal "$stderr" ""
  refute_output --partial "personal"
  assert_output --partial "reconciled (install): $skills/alpha"
  assert_output --partial "reconciled (install): $skills/beta"
  assert_equal "$(jq -r 'has("satisfiedByPersonalScope")' "$lock")" "false"

  mkdir -p "$personal/unrelated"
  printf -- '---\nname: unrelated\n---\n' >"$personal/unrelated/SKILL.md"
  reconcile
  assert_success
  assert_equal "$stderr" ""
  refute_output --partial "personal"
  refute_output --partial "reconciled ("
  assert_store_symlink "$skills/alpha"
  assert_store_symlink "$skills/beta"
  assert_equal "$(jq -r 'has("satisfiedByPersonalScope")' "$lock")" "false"
}

@test "--strict fails the reconcile when a skill differs from the personal scope's copy" {
  mkdir -p "$personal"
  ln -s "$beta_other_src" "$personal/beta"

  reconcile --strict
  assert_failure 1
  assert_store_symlink "$skills/beta"
  assert_equal "${#stderr_lines[@]}" 2
  assert_regex "${stderr_lines[0]}" '^ERROR: beta is sha256:[0-9a-f]{12} in the personal scope'
  assert_regex "${stderr_lines[1]}" ": 1 declared skill\\(s\\) differ from the personal scope's copy \\(--strict\\)\\.$"

  ln -sfn "$beta_src" "$personal/beta"
  reconcile --strict
  assert_success
  assert_equal "$stderr" ""
}

@test "--ignore-personal-scope installs every skill and warns about none" {
  copy_as_older_build "$alpha_src" "$personal/alpha"
  ln -s "$beta_other_src" "$personal/beta"
  reconcile
  assert_success
  refute [ -L "$skills/alpha" ]

  reconcile --ignore-personal-scope
  assert_success
  assert_equal "$stderr" ""
  assert_output --partial "reconciled (install): $skills/alpha"
  assert_store_symlink "$skills/alpha"
  assert_store_symlink "$skills/beta"
  assert_equal "$(jq -r '.skills | has("alpha") and has("beta")' "$lock")" "true"
  assert_equal "$(jq -r 'has("satisfiedByPersonalScope")' "$lock")" "false"
}

@test "--strict and --ignore-personal-scope are refused together, and at another scope" {
  reconcile --strict --ignore-personal-scope
  assert_failure 2
  assert_regex "${stderr_lines[0]}" ': --strict and --ignore-personal-scope contradict each other$'
  refute [ -e "$skills" ]

  run --separate-stderr "$RECONCILE_APP" "${scope_args[@]}" --strict
  assert_failure 2
  assert_regex "${stderr_lines[0]}" ': --strict is only valid with --scope=project \(got --scope=custom\)$'
  refute [ -e "$CUSTOM_TARGET" ]
}
