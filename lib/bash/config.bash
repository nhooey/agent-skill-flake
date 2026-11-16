# config.bash — reading agent-skill-flake's TOML config files.
#
# Three files, all TOML, all read through Nix (`builtins.fromTOML`) into
# JSON so jq can work on them:
#
#   shipped      $shipped_defaults_file, set by the Nix wrapper: every
#                setting with its default (lib/config/defaults.toml)
#   user-global  ${XDG_CONFIG_HOME:-$HOME/.config}/agent-skill-flake/config.toml
#   local        <repo-root>/.config/agent-skill-flake/config.local.toml
#
# The shipped file holds `[defaults]`, `[repo]` and one `[agents.<agent>]`
# table per agent with a writer. The user-global file names only what it
# changes, and adds one `[repo."<host>/<owner>/<name>"]` table per
# repository. The local file has the shape of one repo table, plus an
# optional top-level `merge` table. The shipped file is also the schema:
# validate_config refuses any key it doesn't have.
#
# Resolving a repo's effective settings (resolve_repo_config), where
# `[defaults]` means the user's `[defaults]` deep-merged over the shipped
# one:
#   - no local file: the repo entry, deep-merged over `[defaults]`;
#   - a local file without `merge`: the local file replaces the repo entry
#     entirely, and is deep-merged over `[defaults]`;
#   - a local file with `merge`: the local file is deep-merged over the
#     repo entry (itself deep-merged over `[defaults]`), except that each
#     dotted path in `merge.override` is taken whole from the local file.
# Deep merge: tables merge key by key, recursively; any other value (a
# string, number, boolean or array) from the higher layer replaces the
# lower one.
#
# Requires: jq, and `nix-instantiate` on PATH (the user's Nix).

LOCAL_CONFIG_RELPATH=".config/agent-skill-flake/config.local.toml"

# Path of the user-global config file.
global_config_file() {
  printf '%s/agent-skill-flake/config.toml' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# local_config_file <repo-root> — path of the in-checkout override file.
local_config_file() {
  printf '%s/%s' "$1" "$LOCAL_CONFIG_RELPATH"
}

# read_toml <file> — print the file's contents as JSON. Returns non-zero,
# with Nix's parse error on stderr, if the file is not valid TOML. The
# dummy store keeps the evaluation off the real store: nothing is built
# or written.
read_toml() {
  local file=$1
  if ! command -v nix-instantiate >/dev/null 2>&1; then
    printf 'agent-skill-flake: nix-instantiate is not on PATH; it is needed to read %s\n' "$file" >&2
    return 1
  fi
  nix-instantiate --eval --strict --json --store dummy:// \
    --argstr path "$file" \
    --expr '{ path }: builtins.fromTOML (builtins.readFile path)'
}

# read_shipped_defaults — the shipped defaults file as JSON.
read_shipped_defaults() {
  read_toml "$shipped_defaults_file"
}

# read_toml_if_present <file> — JSON of <file>, or `null` if it is absent.
read_toml_if_present() {
  if [ -f "$1" ]; then
    read_toml "$1"
  else
    printf 'null'
  fi
}

# normalize_origin <git-url> — the `<host>/<owner>/<name>` key a repo table
# is looked up by. Handles scp-like (`git@host:owner/name.git`), URL
# (`https://host/owner/name(.git)`, `ssh://git@host[:port]/owner/name`) and
# local-path forms. The user, the port and a trailing `.git` or `/` are
# dropped and the host is lowercased; the path keeps its case. A local path
# is returned as-is, minus the `.git`/`/` suffix.
normalize_origin() {
  local url=$1 rest hostpart host repo_path
  url=${url%/}
  url=${url%.git}
  url=${url%/}
  case "$url" in
  *://*)
    rest=${url#*://}
    hostpart=${rest%%/*}
    repo_path=""
    [ "$rest" != "$hostpart" ] && repo_path=${rest#*/}
    host=${hostpart##*@}
    host=${host%%:*}
    if [ -z "$host" ]; then
      # file:///srv/repo → /srv/repo
      printf '/%s' "$repo_path"
      return 0
    fi
    ;;
  /* | ./* | ../*)
    printf '%s' "$url"
    return 0
    ;;
  *:*)
    hostpart=${url%%:*}
    case "$hostpart" in
    */*)
      # A colon after a slash: a relative path, not scp-like syntax.
      printf '%s' "$url"
      return 0
      ;;
    esac
    host=${hostpart##*@}
    repo_path=${url#*:}
    ;;
  *)
    printf '%s' "$url"
    return 0
    ;;
  esac
  repo_path=${repo_path#/}
  printf '%s/%s' "${host,,}" "$repo_path"
}

# jq definitions shared by the functions below.
# shellcheck disable=SC2016 # jq source, not shell
CONFIG_JQ_DEFS='
  def fail($msg): error("agent-skill-flake: " + $msg);

  # Deep-merge $o over $b. $p is the current path, $ov the dotted paths
  # whose subtree is taken whole from $o.
  def dmerge($b; $o; $ov; $p):
    if ($b | type) == "object" and ($o | type) == "object"
       and (($p | length) == 0 or (($p | join(".")) as $dp | $ov | index([$dp]) | not))
    then reduce ($o | keys_unsorted[]) as $k ($b;
      .[$k] = (if $b | has($k) then dmerge($b[$k]; $o[$k]; $ov; $p + [$k]) else $o[$k] end))
    else $o end;
  def dmerge($b; $o): dmerge($b; $o; []; []);
'

# validate_config <shipped-json> <global-json> <local-json>
# Refuse any key the shipped defaults don't have: in the user-global file
# (top level, `[defaults]`, each repo table, `[agents]` and each agent's
# table) and in the local file (a repo table's keys plus `merge`, whose
# only key is `override`). <global-json> or <local-json> may be `null` for
# an absent file. Returns non-zero, with the file and key on stderr.
validate_config() {
  jq -n \
    --argjson s "$1" \
    --argjson g "$2" \
    --argjson l "$3" \
    --arg gfile "$(global_config_file)" \
    --arg lfile "$LOCAL_CONFIG_RELPATH" "$CONFIG_JQ_DEFS"'
    # check($file; $where; $have; $known): fail on the first key of the
    # table $have that is not a key of $known.
    def check($file; $where; $have; $known):
      if ($have | type) != "object" then .
      else (($have | keys) - $known) as $bad
        | if ($bad | length) == 0 then .
          else fail($file + ": unknown key `" + $where + $bad[0]
                    + "`; known keys there: " + ($known | join(", ")))
          end
      end;

    ($s.defaults | keys) as $repo_keys
    | check($gfile; ""; $g; $s | keys)
    | check($gfile; "defaults."; $g.defaults; $repo_keys)
    | reduce ((($g.repo // {}) | if type == "object" then to_entries[] else empty end)) as $r (.;
        check($gfile; "repo.\"" + $r.key + "\"."; $r.value; $repo_keys))
    | check($gfile; "agents."; $g.agents; $s.agents | keys)
    | reduce ((($g.agents // {}) | if type == "object" then to_entries[] else empty end)) as $a (.;
        check($gfile; "agents." + $a.key + "."; $a.value; $s.agents[$a.key] | keys))
    | check($lfile; ""; $l; $repo_keys + ["merge"])
    | check($lfile; "merge."; ($l // {}).merge; ["override"])
    | empty'
}

# merge_over_defaults <shipped-json> <global-json> — the user-global config
# deep-merged over the shipped defaults: the settings `apply` reads.
merge_over_defaults() {
  jq -n --argjson s "$1" --argjson g "$2" "$CONFIG_JQ_DEFS"'
    if ($g | type) != "object" then fail("the user-global config is not a table")
    else dmerge($s; $g) end'
}

# resolve_repo_config <global-json> <local-json> <repo-key> <shipped-json>
# Print a JSON object describing the repo's effective settings:
#   {found: false}                      no repo entry and no local file
#   {found: true, mode, effective, skillsOrigin}
# where mode is "user-global" (no local file), "replace" or "merge", and
# skillsOrigin names the layer `skills` came from: "local", "user-global"
# (the repo entry), "user-global defaults" or "shipped defaults".
# Returns non-zero, with the reason on stderr, on a malformed config.
resolve_repo_config() {
  jq -n \
    --argjson g "$1" \
    --argjson l "$2" \
    --arg key "$3" \
    --argjson s "$4" "$CONFIG_JQ_DEFS"'
    ($g // {}) as $g
    | (if ($g | type) != "object" then fail("the user-global config is not a table") else . end)
    | ($g.defaults // {}) as $ud
    | (if ($ud | type) != "object" then fail("[defaults] must be a table") else . end)
    | dmerge($s.defaults; $ud) as $d
    | (($g.repo // {}) | if type != "object" then fail("[repo] must be a table") else . end) as $repos
    | $repos[$key] as $e
    | (if $e != null and ($e | type) != "object"
       then fail("repo.\"" + $key + "\" must be a table") else . end)
    | if $l == null and $e == null then {found: false}
      else
        ($l | if . == null then null else del(.merge) end) as $lv
        | ($l | if . == null then null else .merge end) as $m
        | (if $m != null and ($m | type) != "object"
           then fail("`merge` in the local config must be a table, e.g. merge = { override = [\"skills\"] }")
           else . end)
        | (($m // {}).override // []) as $ov
        | (if ($ov | type) != "array" or ($ov | map(type == "string") | all | not)
           then fail("merge.override must be a list of dotted paths (strings)") else . end)
        | (if $l == null then {mode: "user-global", effective: dmerge($d; $e)}
           elif $m == null then {mode: "replace", effective: dmerge($d; $lv)}
           else {mode: "merge", effective: dmerge(dmerge($d; ($e // {})); $lv; $ov; [])}
           end) as $r
        | ($r.effective.skills) as $sk
        | (if ($sk | type) != "array" or ($sk | map(type == "string") | all | not)
           then fail("`skills` must be a list of flake installables (strings)") else . end)
        | {
            found: true,
            mode: $r.mode,
            effective: $r.effective,
            skillsOrigin: (
              if ($lv // {}) | has("skills") then "local"
              elif $r.mode != "replace" and (($e // {}) | has("skills")) then "user-global"
              elif $ud | has("skills") then "user-global defaults"
              else "shipped defaults" end)
          }
      end'
}
