#!/usr/bin/env bats
# Inputs: ROOT_CHECK_DEPENDENCIES — the root-check-dependencies command.
# Runs it on a scratch git repository against a stub `nix`, whose eval
# writes a listing file and records its argv, and a stub `nix-store`, whose
# --add-root links the listing, so the test pins where the root lives, what
# the evaluation asks for, and when a refresh runs, without a Nix store.
setup() {
  source "$BATS_HELPERS"
  export HOME="$BATS_TEST_TMPDIR/home"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  mkdir -p "$HOME"
  git config --global user.name test
  git config --global user.email test@example.invalid
  git config --global init.defaultBranch master

  export STUB_LOG="$BATS_TEST_TMPDIR/nix-calls"
  export STUB_STORE="$BATS_TEST_TMPDIR/store"
  export STUB_KEEP_OUTPUTS=true
  export STUB_EVAL_FAILS=0
  mkdir -p "$STUB_STORE"
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat >"$bin/nix" <<'STUB'
#!/usr/bin/env bash
printf 'nix %s\n' "$*" >>"$STUB_LOG"
case "$1 $2" in
"config show") printf '%s\n' "$STUB_KEEP_OUTPUTS" ;;
"eval --raw")
  printf '%s' "${!#}" >"$STUB_LOG.apply"
  [ "$STUB_EVAL_FAILS" = 1 ] && exit 1
  listing="$STUB_STORE/$(date +%s%N)-check-dependencies"
  printf '/nix/store/a.drv\n/nix/store/b.drv\n' >"$listing"
  printf '%s' "$listing"
  ;;
esac
STUB
  cat >"$bin/nix-store" <<'STUB'
#!/usr/bin/env bash
printf 'nix-store %s\n' "$*" >>"$STUB_LOG"
[ "$1" = --add-root ] && ln -sfn "${!#}" "$2"
STUB
  chmod +x "$bin/nix" "$bin/nix-store"
  export PATH="$bin:$PATH"

  repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '{ }\n' >"$repo/flake.nix"
  printf '{"version": 7}\n' >"$repo/flake.lock"
  printf 'notes\n' >"$repo/README.md"
  git -C "$repo" add flake.nix flake.lock README.md
  git -C "$repo" commit -qm init
  link="$repo/.git/agent-skill-flake/check-dependencies"
}

evals() {
  if [ -f "$STUB_LOG" ]; then
    grep -c '^nix eval' "$STUB_LOG" || true
  else
    echo 0
  fi
}

@test "roots the evaluated listing at the git common dir, and git sees nothing new" {
  run "$ROOT_CHECK_DEPENDENCIES" --flake="$repo" --system=x86_64-linux
  assert_success
  assert_output --partial "rooted 2 check derivations at $link"
  assert [ -L "$link" ]
  assert_equal "$(cat "$link")" "$(printf '/nix/store/a.drv\n/nix/store/b.drv')"
  assert_equal "$(git -C "$repo" status --porcelain)" ""
}

@test "evaluates with no build slots, and roots indirectly" {
  run "$ROOT_CHECK_DEPENDENCIES" --flake="$repo" --system=x86_64-linux
  assert_success
  run grep '^nix eval' "$STUB_LOG"
  assert_output --partial "nix eval --raw --max-jobs 0 --builders  $repo#checks.x86_64-linux --apply"
  assert_file_contains "$STUB_LOG.apply" "unsafeDiscardOutputDependency"
  run grep '^nix-store' "$STUB_LOG"
  assert_output "nix-store --add-root $link --indirect --realise $(readlink "$link")"
}

@test "skips the evaluation while no Nix or lock file changed" {
  "$ROOT_CHECK_DEPENDENCIES" --flake="$repo"
  printf 'more notes\n' >>"$repo/README.md"
  run "$ROOT_CHECK_DEPENDENCIES" --flake="$repo"
  assert_success
  assert_output --partial "is up to date"
  assert_equal "$(evals)" 1
}

@test "refreshes when the lock changes, replacing the root" {
  "$ROOT_CHECK_DEPENDENCIES" --flake="$repo"
  local first
  first=$(readlink "$link")
  printf '{"version": 8}\n' >"$repo/flake.lock"
  run "$ROOT_CHECK_DEPENDENCIES" --flake="$repo"
  assert_success
  assert_equal "$(evals)" 2
  refute [ "$(readlink "$link")" = "$first" ]
}

@test "refreshes when a new untracked Nix file appears, or with --force" {
  "$ROOT_CHECK_DEPENDENCIES" --flake="$repo"
  printf '{ }\n' >"$repo/checks.nix"
  "$ROOT_CHECK_DEPENDENCIES" --flake="$repo"
  assert_equal "$(evals)" 2
  "$ROOT_CHECK_DEPENDENCIES" --flake="$repo" --force
  assert_equal "$(evals)" 3
}

@test "a worktree shares the repository's one root" {
  "$ROOT_CHECK_DEPENDENCIES" --flake="$repo"
  git -C "$repo" worktree add -q "$BATS_TEST_TMPDIR/wt"
  run "$ROOT_CHECK_DEPENDENCIES" --flake="$BATS_TEST_TMPDIR/wt"
  assert_success
  assert_output --partial "$link is up to date"
}

@test "a failed evaluation leaves the root as it was" {
  "$ROOT_CHECK_DEPENDENCIES" --flake="$repo"
  local first
  first=$(readlink "$link")
  export STUB_EVAL_FAILS=1
  run "$ROOT_CHECK_DEPENDENCIES" --flake="$repo" --force
  assert_failure
  assert_output --partial "left as it was"
  assert_equal "$(readlink "$link")" "$first"
}

@test "warns when keep-outputs is off" {
  export STUB_KEEP_OUTPUTS=false
  run "$ROOT_CHECK_DEPENDENCIES" --flake="$repo"
  assert_success
  assert_output --partial "keep-outputs is not true"
}

@test "--background returns before the refresh and logs it" {
  run "$ROOT_CHECK_DEPENDENCIES" --flake="$repo" --background
  assert_success
  assert_output ""
  local i
  for i in $(seq 1 50); do
    [ -L "$link" ] && grep -q rooted "$link.log" 2>/dev/null && break
    sleep 0.1
  done
  assert [ -L "$link" ]
  assert_file_contains "$link.log" "rooted 2 check derivations"
}

@test "outside a git repository it roots nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run "$ROOT_CHECK_DEPENDENCIES" --flake="$BATS_TEST_TMPDIR/plain"
  assert_success
  assert_output --partial "not in a git repository"
  assert_equal "$(evals)" 0
}
