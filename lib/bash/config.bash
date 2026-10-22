# config.bash — reading agent-skill-flake's TOML config files.
#
# Two files, both TOML, both read through Nix (`builtins.fromTOML`) into
# JSON so jq can work on them:
#
#   user-global  ${XDG_CONFIG_HOME:-$HOME/.config}/agent-skill-flake/config.toml
#   local        <repo-root>/.config/agent-skill-flake/config.local.toml
#
# The user-global file holds `[defaults]`, one `[repo."<host>/<owner>/<name>"]`
# table per repository and `[agents.<agent>]` tables. The local file has the
# shape of one repo table, plus an optional top-level `merge` table.
#
# Resolving a repo's effective settings (resolve_repo_config):
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

# resolve_repo_config <global-json> <local-json> <repo-key>
# Print a JSON object describing the repo's effective settings:
#   {found: false}                      no repo entry and no local file
#   {found: true, mode, effective, skillsOrigin}
# where mode is "user-global" (no local file), "replace" or "merge", and
# skillsOrigin names the layer `skills` came from: "local", "user-global"
# (the repo entry), "user-global defaults", or null when no layer sets it.
# Returns non-zero, with the reason on stderr, on a malformed config.
resolve_repo_config() {
  jq -n \
    --argjson g "$1" \
    --argjson l "$2" \
    --arg key "$3" '
    def fail($msg): error("agent-skill-flake: " + $msg);

    # Deep-merge $o over $b. $p is the current path, $ov the dotted paths
    # whose subtree is taken whole from $o.
    def dmerge($b; $o; $ov; $p):
      if ($b | type) == "object" and ($o | type) == "object"
         and (($p | length) == 0 or (($p | join(".")) as $dp | $ov | index([$dp]) | not))
      then reduce ($o | keys_unsorted[]) as $k ($b;
        .[$k] = (if $b | has($k) then dmerge($b[$k]; $o[$k]; $ov; $p + [$k]) else $o[$k] end))
      else $o end;

    ($g // {}) as $g
    | (if ($g | type) != "object" then fail("the user-global config is not a table") else . end)
    | ($g.defaults // {}) as $d
    | (if ($d | type) != "object" then fail("[defaults] must be a table") else . end)
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
        | (if $l == null then {mode: "user-global", effective: dmerge($d; $e; []; [])}
           elif $m == null then {mode: "replace", effective: dmerge($d; $lv; []; [])}
           else {mode: "merge", effective: dmerge(dmerge($d; ($e // {}); []; []); $lv; $ov; [])}
           end) as $r
        | ($r.effective.skills) as $s
        | (if $s != null and (($s | type) != "array" or ($s | map(type == "string") | all | not))
           then fail("`skills` must be a list of flake installables (strings)") else . end)
        | {
            found: true,
            mode: $r.mode,
            effective: $r.effective,
            skillsOrigin: (
              if ($lv // {}) | has("skills") then "local"
              elif $r.mode != "replace" and (($e // {}) | has("skills")) then "user-global"
              elif $d | has("skills") then "user-global defaults"
              else null end)
          }
      end'
}
