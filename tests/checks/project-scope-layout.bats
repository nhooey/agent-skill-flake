#!/usr/bin/env bats
# Inputs: INSTALL_ALL_APP, RECONCILE_ALL_APP, UNINSTALL_ALL_APP,
#         PURGE_ALL_APP — the aggregate's verbs (alpha + beta, claude-code
#         profile); ALPHA_PKG — alpha's store path.
#
# The project-scope layout install and reconcile keep: skills in
# <root>/.agents/skills, <root>/.claude/skills -> ../.agents/skills, the link
# and each installed skill listed in <git-common-dir>/info/exclude (anything
# else in .agents/skills left visible to git), and the migration of a
# flake-only .claude/skills directory (refused when it holds anything else),
# and a symlink or file there moved aside. Uninstall and purge rewrite the
# exclude block too, so a removed skill's line never hides a folder of the
# project's own.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
}

run_in_dir() {
  local dir=$1
  shift
  run bash -c "cd \"$dir\" && \"\$@\"" -- "$@"
}

make_repo() {
  local dir=$1
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q -b main
    git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  )
}

assert_layout() {
  local proj=$1 exclude=$2
  assert [ -d "$proj/.agents/skills" ]
  refute [ -L "$proj/.agents/skills" ]
  assert_store_symlink "$proj/.agents/skills/alpha"
  assert_store_symlink "$proj/.agents/skills/beta"
  assert [ -L "$proj/.claude/skills" ]
  assert_equal "$(readlink "$proj/.claude/skills")" "../.agents/skills"
  assert [ -f "$proj/.claude/skills/alpha/SKILL.md" ]
  assert_equal "$(grep -cxF '/.claude/skills' "$exclude")" "1"
  assert_equal "$(grep -cxF '/.agents/skills/.agent-skill-flake-lock.json*' "$exclude")" "1"
  assert_equal "$(grep -cxF '/.agents/skills/alpha' "$exclude")" "1"
  assert_equal "$(grep -cxF '/.agents/skills/beta' "$exclude")" "1"
  # Only what the flake manages, never the whole directory.
  refute grep -qxF '/.agents/skills/' "$exclude"
}

@test "a file the project adds to .agents/skills stays visible to git" {
  local proj="$BATS_TEST_TMPDIR/own-files"
  make_repo "$proj"

  run_in_dir "$proj" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  mkdir -p "$proj/.agents/skills/team-skill"
  echo ours >"$proj/.agents/skills/team-skill/SKILL.md"
  echo prefs >"$proj/.agents/skills/alpha.preferences.md"

  run git -C "$proj" status --porcelain --untracked-files=all
  assert_success
  assert_output --partial ".agents/skills/team-skill/SKILL.md"
  assert_output --partial ".agents/skills/alpha.preferences.md"
  refute_output --partial ".agents/skills/alpha/"
  refute_output --partial "lock.json"
}

@test "the exclude block is rewritten to the skills the lock lists" {
  local proj="$BATS_TEST_TMPDIR/block"
  make_repo "$proj"
  printf '# kept\n/build/\n' >>"$proj/.git/info/exclude"

  run_in_dir "$proj" "$INSTALL_ALL_APP" alpha --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  assert grep -qxF '/.agents/skills/alpha' "$proj/.git/info/exclude"
  refute grep -qxF '/.agents/skills/beta' "$proj/.git/info/exclude"

  run_in_dir "$proj" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  assert_layout "$proj" "$proj/.git/info/exclude"
  assert_equal "$(grep -cxF '# agent-skill-flake: end' "$proj/.git/info/exclude")" "1"
  assert grep -qxF '/build/' "$proj/.git/info/exclude"
  assert grep -qxF '# kept' "$proj/.git/info/exclude"
}

@test "fresh install creates .agents/skills, the .claude/skills link, and exclude lines" {
  local proj="$BATS_TEST_TMPDIR/fresh"
  make_repo "$proj"

  run_in_dir "$proj" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  assert_output --partial "linked: $proj/.claude/skills -> ../.agents/skills"

  assert_layout "$proj" "$proj/.git/info/exclude"
  assert jq -e '.skills.alpha.installedBy' "$proj/.agents/skills/.agent-skill-flake-lock.json"
  # Ignored by git, with no tracked file touched.
  refute [ -e "$proj/.gitignore" ]
  run git -C "$proj" status --porcelain
  assert_success
  assert_output ""
}

@test "re-running install and reconcile changes nothing and adds no duplicate lines" {
  local proj="$BATS_TEST_TMPDIR/idem"
  make_repo "$proj"

  run_in_dir "$proj" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  local exclude_before
  exclude_before=$(cat "$proj/.git/info/exclude")

  run_in_dir "$proj" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  refute_output --partial "linked:"
  refute_output --partial "excluded:"
  refute_output --partial "migrated:"

  run_in_dir "$proj" "$RECONCILE_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  refute_output --partial "linked:"
  refute_output --partial "excluded:"
  refute_output --partial "reconciled (install): "

  assert_equal "$(cat "$proj/.git/info/exclude")" "$exclude_before"
  assert_layout "$proj" "$proj/.git/info/exclude"
}

@test "a .claude/skills directory holding only flake-installed entries is migrated" {
  local proj="$BATS_TEST_TMPDIR/migrate"
  make_repo "$proj"
  # The pre-move layout: a real .claude/skills directory the installer filled.
  run "$INSTALL_ALL_APP" --scope=custom --root="$proj/.claude/skills" --gcroots-dir="$GCROOTS_DIR"
  assert_success
  # Plus a stray link recognized only by its sentinel (no lock entry).
  ln -s "$ALPHA_PKG/share/claude-skills/alpha" "$proj/.claude/skills/old-alpha"
  refute [ -L "$proj/.claude/skills" ]

  run_in_dir "$proj" "$RECONCILE_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  assert_output --partial "migrated: $proj/.claude/skills -> $proj/.agents/skills"

  assert_layout "$proj" "$proj/.git/info/exclude"
  assert jq -e '.skills.beta.installedBy' "$proj/.agents/skills/.agent-skill-flake-lock.json"
  # The migrated stray is ours, so reconcile swept it from its new home.
  refute [ -e "$proj/.agents/skills/old-alpha" ]
}

@test "migration merges into an existing .agents/skills directory" {
  local proj="$BATS_TEST_TMPDIR/merge"
  make_repo "$proj"
  run "$INSTALL_ALL_APP" --scope=custom --root="$proj/.claude/skills" --gcroots-dir="$GCROOTS_DIR" alpha
  assert_success
  mkdir -p "$proj/.agents/skills/other-agent-skill"

  run_in_dir "$proj" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  assert_output --partial "migrated:"

  assert_layout "$proj" "$proj/.git/info/exclude"
  assert [ -d "$proj/.agents/skills/other-agent-skill" ]
}

@test "migration is refused, with nothing changed, when .claude/skills holds a foreign entry" {
  local proj="$BATS_TEST_TMPDIR/refuse"
  make_repo "$proj"
  run "$INSTALL_ALL_APP" --scope=custom --root="$proj/.claude/skills" --gcroots-dir="$GCROOTS_DIR"
  assert_success
  mkdir -p "$proj/.claude/skills/my-own-skill"
  echo mine >"$proj/.claude/skills/my-own-skill/SKILL.md"
  ln -s /nowhere "$proj/.claude/skills/my-link"

  local before exclude_before
  before=$(snapshot_fs "$proj")
  exclude_before=$(cat "$proj/.git/info/exclude")

  run_in_dir "$proj" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_failure
  assert_output --partial "did not install"
  assert_output --partial "my-own-skill"
  assert_output --partial "my-link"
  refute_output --partial "  alpha"

  assert_equal "$(snapshot_fs "$proj")" "$before"
  assert_equal "$(cat "$proj/.git/info/exclude")" "$exclude_before"
  refute [ -e "$proj/.agents" ]
  refute [ -L "$proj/.claude/skills" ]

  run_in_dir "$proj" "$RECONCILE_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_failure
  assert_equal "$(snapshot_fs "$proj")" "$before"
}

@test "a .claude/skills symlink to elsewhere is moved aside, its target untouched" {
  local proj="$BATS_TEST_TMPDIR/foreign-link" other="$BATS_TEST_TMPDIR/elsewhere"
  make_repo "$proj"
  mkdir -p "$other/kept" "$proj/.claude"
  echo kept >"$other/kept/SKILL.md"
  ln -s "$other" "$proj/.claude/skills"

  run_in_dir "$proj" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  assert_output --partial "moved aside: $proj/.claude/skills (a symlink to $other)"

  assert_layout "$proj" "$proj/.git/info/exclude"
  assert_equal "$(readlink "$proj/.claude/skills.pre-agent-skill-flake")" "$other"
  assert_equal "$(cat "$other/kept/SKILL.md")" "kept"
  refute [ -e "$other/alpha" ]
}

@test "a .claude/skills file is moved aside" {
  local proj="$BATS_TEST_TMPDIR/foreign-file"
  make_repo "$proj"
  mkdir -p "$proj/.claude"
  echo notes >"$proj/.claude/skills"

  run_in_dir "$proj" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  assert_output --partial "moved aside: $proj/.claude/skills (a file)"

  assert_layout "$proj" "$proj/.git/info/exclude"
  assert_equal "$(cat "$proj/.claude/skills.pre-agent-skill-flake")" "notes"
}

@test "a .claude/skills symlink already resolving to .agents/skills is rewritten relative" {
  local proj="$BATS_TEST_TMPDIR/absolute-link"
  make_repo "$proj"
  mkdir -p "$proj/.agents/skills" "$proj/.claude"
  ln -s "$proj/.agents/skills" "$proj/.claude/skills"

  run_in_dir "$proj" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  refute_output --partial "moved aside"

  assert_layout "$proj" "$proj/.git/info/exclude"
  refute [ -e "$proj/.claude/skills.pre-agent-skill-flake" ]
}

@test "moving aside is refused, with nothing changed, when the aside name is taken" {
  local proj="$BATS_TEST_TMPDIR/aside-taken"
  make_repo "$proj"
  mkdir -p "$proj/.claude"
  echo notes >"$proj/.claude/skills"
  echo older >"$proj/.claude/skills.pre-agent-skill-flake"

  local before
  before=$(snapshot_fs "$proj")

  run_in_dir "$proj" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_failure
  assert_output --partial "already exists; nothing was changed"

  assert_equal "$(snapshot_fs "$proj")" "$before"
  refute [ -e "$proj/.agents" ]
}

@test "from a linked worktree, the exclude lines go to the common git dir" {
  local proj="$BATS_TEST_TMPDIR/main-checkout" wt="$BATS_TEST_TMPDIR/linked-wt"
  make_repo "$proj"
  git -C "$proj" worktree add -q -b side "$wt"
  assert [ -f "$wt/.git" ]

  run_in_dir "$wt" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success

  assert_layout "$wt" "$proj/.git/info/exclude"
  refute [ -e "$proj/.agents" ]
  run git -C "$wt" status --porcelain
  assert_success
  assert_output ""
}

@test "uninstall drops the skill's exclude line, so a project folder of that name shows in git" {
  local proj="$BATS_TEST_TMPDIR/uninstall-excludes"
  make_repo "$proj"
  local exclude="$proj/.git/info/exclude"

  run_in_dir "$proj" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  run_in_dir "$proj" "$UNINSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR" alpha
  assert_success

  refute grep -qxF '/.agents/skills/alpha' "$exclude"
  assert_equal "$(grep -cxF '/.agents/skills/beta' "$exclude")" "1"
  assert_equal "$(grep -cxF '/.claude/skills' "$exclude")" "1"

  mkdir -p "$proj/.agents/skills/alpha"
  echo ours >"$proj/.agents/skills/alpha/SKILL.md"
  run git -C "$proj" status --porcelain --untracked-files=all
  assert_success
  assert_output "?? .agents/skills/alpha/SKILL.md"
}

@test "purge drops every skill's exclude line and keeps the link and lock lines" {
  local proj="$BATS_TEST_TMPDIR/purge-excludes"
  make_repo "$proj"
  local exclude="$proj/.git/info/exclude"

  run_in_dir "$proj" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success
  run_in_dir "$proj" "$PURGE_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR" --yes
  assert_success

  refute grep -qxF '/.agents/skills/alpha' "$exclude"
  refute grep -qxF '/.agents/skills/beta' "$exclude"
  assert_equal "$(grep -cxF '/.claude/skills' "$exclude")" "1"
  assert_equal "$(grep -cxF '/.agents/skills/.agent-skill-flake-lock.json*' "$exclude")" "1"
}

@test "the block's begin line is the one every earlier version matches" {
  local proj="$BATS_TEST_TMPDIR/begin-line"
  make_repo "$proj"
  local exclude="$proj/.git/info/exclude"

  run_in_dir "$proj" "$INSTALL_ALL_APP" --scope=project --gcroots-dir="$GCROOTS_DIR"
  assert_success

  assert_equal "$(grep -cxF '# agent-skill-flake: begin (rewritten by install and reconcile)' "$exclude")" "1"
}
