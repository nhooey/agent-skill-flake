#!/usr/bin/env bats
# Inputs: CONFIG_BASH — lib/bash/config.bash, sourced directly;
#         DEFAULTS_TOML — lib/config/defaults.toml, the shipped defaults.
#
# The user config: the shipped defaults complete and commented, an empty
# user config giving exactly the defaults, unknown keys refused, TOML read
# through Nix into JSON, origin URLs normalized to the
# `<host>/<owner>/<name>` repo key, and the precedence rules — the local
# file replaces the user-global repo entry by default, and with a `merge`
# table is deep-merged over it, with `merge.override` paths taken whole
# from the local file. The precedence tests use keys outside the schema to
# show nested merging: resolve_repo_config merges, validate_config checks.
setup() {
  source "$BATS_HELPERS"
  setup_isolated_env
  source "$CONFIG_BASH"
  shipped_defaults_file=$DEFAULTS_TOML
  SHIPPED=$(read_shipped_defaults)
}

# resolve <global-toml> <local-toml|-> <key> — resolve_repo_config over two
# TOML snippets, `-` meaning no local file. Output: the result JSON.
resolve() {
  local global_json local_json="null"
  printf '%s\n' "$1" >"$BATS_TEST_TMPDIR/global.toml"
  global_json=$(read_toml "$BATS_TEST_TMPDIR/global.toml")
  if [ "$2" != "-" ]; then
    printf '%s\n' "$2" >"$BATS_TEST_TMPDIR/local.toml"
    local_json=$(read_toml "$BATS_TEST_TMPDIR/local.toml")
  fi
  resolve_repo_config "$global_json" "$local_json" "$3" "$SHIPPED"
}

# validate <global-toml|-> <local-toml|-> — validate_config over two TOML
# snippets, `-` meaning an absent file.
validate() {
  local global_json="null" local_json="null"
  if [ "$1" != "-" ]; then
    printf '%s\n' "$1" >"$BATS_TEST_TMPDIR/global.toml"
    global_json=$(read_toml "$BATS_TEST_TMPDIR/global.toml")
  fi
  if [ "$2" != "-" ]; then
    printf '%s\n' "$2" >"$BATS_TEST_TMPDIR/local.toml"
    local_json=$(read_toml "$BATS_TEST_TMPDIR/local.toml")
  fi
  validate_config "$SHIPPED" "$global_json" "$local_json"
}

GLOBAL_KNOWN='
[defaults]
skills = ["default-skills"]

[repo."github.com/acme/widget"]
skills = ["global-skills"]

[agents.claude-code]
trusted-dirs = ["~/git"]
'

@test "the shipped defaults set every setting the code reads, and no others" {
  assert_equal "$(jq -c '[paths(type != "object" or . == {}) | join(".")] | sort' <<<"$SHIPPED")" \
    '["agents.claude-code.trusted-dirs","defaults.skills","repo"]'
  assert_equal "$(jq -c .defaults.skills <<<"$SHIPPED")" '[]'
  assert_equal "$(jq -c '.agents."claude-code"."trusted-dirs"' <<<"$SHIPPED")" '[]'
}

@test "every key and table in the shipped defaults has a comment above it" {
  local prev="" line
  while IFS= read -r line; do
    case "$line" in
    '' | '#'*) ;;
    *)
      case "$prev" in
      '#'*) ;;
      *) fail "no comment above: $line" ;;
      esac
      ;;
    esac
    prev=$line
  done <"$DEFAULTS_TOML"
}

@test "an empty user config gives exactly the shipped defaults" {
  run merge_over_defaults "$SHIPPED" '{}'
  assert_success
  assert_equal "$(jq -cS . <<<"$output")" "$(jq -cS . <<<"$SHIPPED")"

  run validate '' -
  assert_success

  run resolve '' 'merge = {}' github.com/acme/widget
  assert_success
  assert_equal "$(jq -c .effective <<<"$output")" '{"skills":[]}'
  assert_equal "$(jq -r .skillsOrigin <<<"$output")" "shipped defaults"
}

@test "a sparse user config changes only its keys" {
  run merge_over_defaults "$SHIPPED" '{"defaults": {"skills": ["s"]}}'
  assert_success
  assert_equal "$(jq -c .defaults.skills <<<"$output")" '["s"]'
  assert_equal "$(jq -c '.agents."claude-code"."trusted-dirs"' <<<"$output")" '[]'
}

@test "an unknown key is refused, naming the file and the key" {
  run validate 'colour = "red"' -
  assert_failure
  assert_output --partial 'config.toml: unknown key `colour`'

  run validate '[defaults]
skils = []' -
  assert_failure
  assert_output --partial 'unknown key `defaults.skils`; known keys there: skills'

  run validate '[repo."github.com/acme/widget"]
tools = { lint = "x" }' -
  assert_failure
  assert_output --partial 'unknown key `repo."github.com/acme/widget".tools`'

  run validate '[agents.some-other-agent]
trusted-dirs = ["/x"]' -
  assert_failure
  assert_output --partial 'unknown key `agents.some-other-agent`'

  run validate '[agents.claude-code]
trusted_dirs = ["/x"]' -
  assert_failure
  assert_output --partial 'unknown key `agents.claude-code.trusted_dirs`'

  run validate - 'notes = "x"'
  assert_failure
  assert_output --partial 'config.local.toml: unknown key `notes`'

  run validate - 'merge = { overide = ["skills"] }'
  assert_failure
  assert_output --partial 'unknown key `merge.overide`'

  run validate "$GLOBAL_KNOWN" 'skills = []
merge = { override = ["skills"] }'
  assert_success
}

GLOBAL='
[defaults]
skills = ["default-skills"]
shared = { from = "defaults", keep = "defaults" }

[repo."github.com/acme/widget"]
skills = ["global-skills"]
extra = "global"
tools = { lint = { cmd = "eslint", args = ["--fix"] }, fmt = { cmd = "prettier" } }
'

@test "origin URLs normalize to <host>/<owner>/<name>" {
  local url
  for url in \
    git@github.com:acme/widget.git \
    git@github.com:acme/widget \
    https://github.com/acme/widget.git \
    https://github.com/acme/widget \
    https://github.com/acme/widget/ \
    https://GitHub.com/acme/widget.git \
    https://user:token@github.com/acme/widget.git \
    ssh://git@github.com/acme/widget \
    ssh://git@github.com:22/acme/widget.git; do
    assert_equal "$(normalize_origin "$url")" "github.com/acme/widget"
  done
  assert_equal "$(normalize_origin https://gitlab.com/group/sub/proj.git)" "gitlab.com/group/sub/proj"
  assert_equal "$(normalize_origin /srv/git/widget.git)" "/srv/git/widget"
  assert_equal "$(normalize_origin file:///srv/git/widget.git)" "/srv/git/widget"
}

@test "the user-global file lives under XDG_CONFIG_HOME, else ~/.config" {
  XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg"
  assert_equal "$(global_config_file)" "$BATS_TEST_TMPDIR/xdg/agent-skill-flake/config.toml"
  unset XDG_CONFIG_HOME
  assert_equal "$(global_config_file)" "$HOME/.config/agent-skill-flake/config.toml"
  assert_equal "$(local_config_file /repo)" "/repo/.config/agent-skill-flake/config.local.toml"
}

@test "TOML is read into JSON, and a parse error fails" {
  printf '%s\n' "$GLOBAL" >"$BATS_TEST_TMPDIR/c.toml"
  run read_toml "$BATS_TEST_TMPDIR/c.toml"
  assert_success
  assert_equal "$(jq -c '.repo."github.com/acme/widget".skills' <<<"$output")" '["global-skills"]'
  assert_equal "$(jq -r '.repo."github.com/acme/widget".tools.lint.args[0]' <<<"$output")" "--fix"

  printf 'skills = [\n' >"$BATS_TEST_TMPDIR/bad.toml"
  run read_toml "$BATS_TEST_TMPDIR/bad.toml"
  assert_failure

  run read_toml_if_present "$BATS_TEST_TMPDIR/absent.toml"
  assert_success
  assert_output "null"
}

@test "with no local file, the repo entry is deep-merged over [defaults]" {
  run resolve "$GLOBAL" - github.com/acme/widget
  assert_success
  assert_equal "$(jq -r .mode <<<"$output")" "user-global"
  assert_equal "$(jq -c .effective.skills <<<"$output")" '["global-skills"]'
  assert_equal "$(jq -r .effective.shared.keep <<<"$output")" "defaults"
  assert_equal "$(jq -r .skillsOrigin <<<"$output")" "user-global"
}

@test "with no repo entry and no local file, nothing is found" {
  run resolve "$GLOBAL" - github.com/acme/other
  assert_success
  assert_equal "$(jq -c . <<<"$output")" '{"found":false}'
}

@test "by default the local file replaces the repo entry entirely" {
  run resolve "$GLOBAL" 'skills = ["local-skills"]
tools = { lint = { cmd = "biome" } }' github.com/acme/widget
  assert_success
  assert_equal "$(jq -r .mode <<<"$output")" "replace"
  assert_equal "$(jq -c .effective.skills <<<"$output")" '["local-skills"]'
  assert_equal "$(jq -c .effective.tools <<<"$output")" '{"lint":{"cmd":"biome"}}'
  # Nothing from the repo entry survives...
  assert_equal "$(jq -r '.effective.extra // "absent"' <<<"$output")" "absent"
  # ...while [defaults] still sit underneath.
  assert_equal "$(jq -r .effective.shared.from <<<"$output")" "defaults"
  assert_equal "$(jq -r .skillsOrigin <<<"$output")" "local"
}

@test "a local file applies to a repo with no user-global entry" {
  run resolve "$GLOBAL" 'skills = ["local-skills"]' github.com/acme/other
  assert_success
  assert_equal "$(jq -r .found <<<"$output")" "true"
  assert_equal "$(jq -c .effective.skills <<<"$output")" '["local-skills"]'
}

@test "a local file without skills takes them from [defaults], not the repo entry" {
  run resolve "$GLOBAL" 'extra = "local"' github.com/acme/widget
  assert_success
  assert_equal "$(jq -c .effective.skills <<<"$output")" '["default-skills"]'
  assert_equal "$(jq -r .skillsOrigin <<<"$output")" "user-global defaults"
}

@test "merge: tables merge recursively and the local value wins elsewhere" {
  run resolve "$GLOBAL" 'merge = {}
extra = "local"
tools = { lint = { args = ["--quiet"] }, test = { cmd = "vitest" } }' github.com/acme/widget
  assert_success
  assert_equal "$(jq -r .mode <<<"$output")" "merge"
  assert_equal "$(jq -r .effective.extra <<<"$output")" "local"
  # A table merges key by key; an array is replaced, not appended.
  assert_equal "$(jq -cS .effective.tools.lint <<<"$output")" '{"args":["--quiet"],"cmd":"eslint"}'
  assert_equal "$(jq -r .effective.tools.fmt.cmd <<<"$output")" "prettier"
  assert_equal "$(jq -r .effective.tools.test.cmd <<<"$output")" "vitest"
  # Untouched keys come from the repo entry, and `merge` itself is dropped.
  assert_equal "$(jq -c .effective.skills <<<"$output")" '["global-skills"]'
  assert_equal "$(jq -r .skillsOrigin <<<"$output")" "user-global"
  assert_equal "$(jq -r '.effective.merge // "absent"' <<<"$output")" "absent"
}

@test "merge.override takes a top-level subtree whole from the local file" {
  run resolve "$GLOBAL" 'merge = { override = ["tools"] }
skills = ["local-skills"]
tools = { lint = { cmd = "biome" } }' github.com/acme/widget
  assert_success
  assert_equal "$(jq -c .effective.tools <<<"$output")" '{"lint":{"cmd":"biome"}}'
  assert_equal "$(jq -r .effective.extra <<<"$output")" "global"
  assert_equal "$(jq -c .effective.skills <<<"$output")" '["local-skills"]'
  assert_equal "$(jq -r .skillsOrigin <<<"$output")" "local"
}

@test "merge.override takes a nested subtree whole, merging around it" {
  run resolve "$GLOBAL" 'merge = { override = ["tools.lint"] }
tools = { lint = { cmd = "biome" }, fmt = { args = ["-w"] } }' github.com/acme/widget
  assert_success
  # tools.lint: the local subtree, its descendants included.
  assert_equal "$(jq -c .effective.tools.lint <<<"$output")" '{"cmd":"biome"}'
  # tools.fmt: still deep-merged.
  assert_equal "$(jq -cS .effective.tools.fmt <<<"$output")" '{"args":["-w"],"cmd":"prettier"}'
}

@test "an override path the local file doesn't set leaves the merged value" {
  run resolve "$GLOBAL" 'merge = { override = ["tools.fmt"] }
tools = { lint = { cmd = "biome" } }' github.com/acme/widget
  assert_success
  assert_equal "$(jq -c .effective.tools.fmt <<<"$output")" '{"cmd":"prettier"}'
  assert_equal "$(jq -cS .effective.tools.lint <<<"$output")" '{"args":["--fix"],"cmd":"biome"}'
}

@test "a malformed config fails with the reason" {
  run resolve "$GLOBAL" 'merge = true' github.com/acme/widget
  assert_failure
  assert_output --partial "merge"

  run resolve "$GLOBAL" 'merge = { override = "skills" }' github.com/acme/widget
  assert_failure
  assert_output --partial "merge.override"

  run resolve "$GLOBAL" 'skills = "not-a-list"' github.com/acme/widget
  assert_failure
  assert_output --partial "skills"

  run resolve 'repo = { "github.com/acme/widget" = "x" }' - github.com/acme/widget
  assert_failure
  assert_output --partial "must be a table"
}
