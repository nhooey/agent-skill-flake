# project-layout.bash — the on-disk layout install and reconcile keep at
# --scope=project, and the exclude block every verb that changes the
# skills directory rewrites.
#
# Skills live in <project-root>/<project_suffix>. When the agent profile
# names a `project_link` (claude-code: `.claude/skills`), that path is a
# relative symlink to project_suffix (`.claude/skills -> ../.agents/skills`),
# so every agent reads the one shared directory. The link, the lock file,
# the `agent-skill-flake sync-project` local config file
# (`.config/agent-skill-flake/config.local.toml`) and each skill the lock
# lists are ignored, one line each, in a marked block of
# `<git-common-dir>/info/exclude` — the common dir, so every linked worktree
# shares it — rewritten after every install, reconcile, uninstall, reap
# and purge. Anything else in
# project_suffix, such as a skill or preferences file the project commits,
# stays visible to git, and no tracked file in the repo is touched.
#
# A project_link that is a real directory is migrated: when every entry in
# it is one this flake installed, the entries move into project_suffix and
# the directory is replaced by the symlink. Any other entry stops the run
# with a non-zero exit, the foreign entries listed, and nothing changed.
# "Installed by this flake" is the ownership test reconcile uses: the lock
# names an installer (`installedBy`) for the entry, or the entry's sentinel
# carries this lineage's `managedBy`, or it is a broken link with a matching
# GC root. The aggregate lock file itself is ours too.
#
# A project_link that is a symlink resolving to project_suffix is rewritten
# to the relative form. Any other symlink, or a file, is moved aside to
# `<project_link>.pre-agent-skill-flake`, its target untouched, and the run
# goes on; if that name is taken, the run stops with nothing changed.
#
# Caller contract:
#   scope.bash parsed  — install_scope, project_root, target_root,
#                        gcroots_dir, project_suffix
#   project_link       — project-root-relative link path, or empty
#   upstream_url       — this lineage's managedBy URL, or empty
#   ownership.bash sourced (is_ours_live, is_ours_broken)

PROJECT_LOCK_FILE=".agent-skill-flake-lock.json"
# The in-checkout config override `agent-skill-flake sync-project` reads
# (see config.bash); never committed, so it is excluded with the rest.
PROJECT_LOCAL_CONFIG=".config/agent-skill-flake/config.local.toml"
# Every version finds the block by this exact line, so its wording stays
# as is, though uninstall, reap and purge now rewrite the block too: a
# version that didn't recognize it would add a second block and leave the
# first one's stale lines in force.
EXCLUDE_BEGIN="# agent-skill-flake: begin (rewritten by install and reconcile)"
EXCLUDE_END="# agent-skill-flake: end"

# Help-text paragraph for the verbs that write the layout. Prints to stdout.
print_project_layout_usage() {
  printf 'Project scope:\n'
  if [ -n "${project_link:-}" ]; then
    printf '  <project-root>/%s is a symlink to %s (a real directory\n' "$project_link" "$(project_link_target)"
    printf '  there that holds only skills this flake installed is moved over).\n'
  fi
  printf '  The skills this flake installed are listed in\n'
  printf '  <git-common-dir>/info/exclude, one line each; anything else\n'
  printf '  there stays visible to git, and no tracked file is changed.\n\n'
}

# The link's literal target: project_suffix, relative to the link's parent.
# `.claude/skills` + `.agents/skills` -> `../.agents/skills`.
project_link_target() {
  local parent="" up=""
  case "$project_link" in
  */*) parent=${project_link%/*} ;;
  esac
  while [ -n "$parent" ]; do
    up="../$up"
    case "$parent" in
    */*) parent=${parent%/*} ;;
    *) parent="" ;;
    esac
  done
  printf '%s%s' "$up" "$project_suffix"
}

# project_link_entry_is_ours <dir> <entry>
project_link_entry_is_ours() {
  local dir=$1 entry=$2 name lock installed_by
  name=$(basename "$entry")
  lock="$dir/$PROJECT_LOCK_FILE"
  if [ "$name" = "$PROJECT_LOCK_FILE" ]; then
    [ -f "$entry" ] && [ ! -L "$entry" ]
    return
  fi
  [ -L "$entry" ] || return 1
  if [ -f "$lock" ]; then
    installed_by=$(jq -r --arg n "$name" '.skills[$n].installedBy // empty' "$lock" 2>/dev/null || true)
    [ -n "$installed_by" ] && return 0
  fi
  if [ -n "${upstream_url:-}" ] && is_ours_live "$entry" "$upstream_url"; then
    return 0
  fi
  is_ours_broken "$entry" "$gcroots_dir"
}

# migrate_project_link_dir <dir>
# Move a flake-only <dir> into $target_root; refuse (return 1, nothing
# changed) if any entry in it is not ours.
migrate_project_link_dir() {
  local dir=$1 entry name
  local -a entries=() foreign=()
  local old_opts
  old_opts=$(shopt -p nullglob dotglob || true)
  shopt -s nullglob dotglob
  entries=("$dir"/*)
  eval "$old_opts"

  for entry in "${entries[@]}"; do
    project_link_entry_is_ours "$dir" "$entry" || foreign+=("$(basename "$entry")")
  done
  if [ ${#foreign[@]} -gt 0 ]; then
    printf '%s: %s is a directory holding entries agent-skill-flake did not install:\n' "$app_name" "$dir" >&2
    for name in "${foreign[@]}"; do
      printf '  %s\n' "$name" >&2
    done
    printf '  Skills now install into %s, with %s linked to it.\n' "$target_root" "$dir" >&2
    printf '  Move those entries out of %s and re-run; nothing was changed.\n' "$dir" >&2
    return 1
  fi

  if [ ! -e "$target_root" ] && [ ! -L "$target_root" ]; then
    mkdir -p "$(dirname "$target_root")"
    mv "$dir" "$target_root"
  else
    for entry in "${entries[@]}"; do
      name=$(basename "$entry")
      [ "$name" = "$PROJECT_LOCK_FILE" ] && continue
      # The entry is a flake-owned link; one already in the target wins.
      if [ -e "$target_root/$name" ] || [ -L "$target_root/$name" ]; then
        rm -f "$entry"
      else
        mv "$entry" "$target_root/$name"
      fi
    done
    if [ -f "$dir/$PROJECT_LOCK_FILE" ]; then
      if [ -f "$target_root/$PROJECT_LOCK_FILE" ]; then
        local tmp="$target_root/$PROJECT_LOCK_FILE.tmp.$$"
        jq -s '.[1] + {skills: ((.[0].skills // {}) + (.[1].skills // {}))}' \
          "$dir/$PROJECT_LOCK_FILE" "$target_root/$PROJECT_LOCK_FILE" >"$tmp"
        mv -f "$tmp" "$target_root/$PROJECT_LOCK_FILE"
        rm -f "$dir/$PROJECT_LOCK_FILE"
      else
        mv "$dir/$PROJECT_LOCK_FILE" "$target_root/$PROJECT_LOCK_FILE"
      fi
    fi
    rmdir "$dir"
  fi
  printf 'migrated: %s -> %s\n' "$dir" "$target_root"
}

# move_project_link_aside <path> <what>
# Rename a symlink or file at the link path to <path>.pre-agent-skill-flake,
# leaving any symlink target untouched; refuse (return 1, nothing changed)
# if that name is taken.
move_project_link_aside() {
  local path=$1 what=$2 aside="$1.pre-agent-skill-flake"
  if [ -e "$aside" ] || [ -L "$aside" ]; then
    printf '%s: %s is %s, and %s already exists; nothing was changed.\n' \
      "$app_name" "$path" "$what" "$aside" >&2
    return 1
  fi
  mv "$path" "$aside"
  printf 'moved aside: %s (%s) -> %s\n' "$path" "$what" "$aside"
}

# Rewrite the marked block of the repo's shared info/exclude to list
# exactly what this flake manages at project scope: project_link, the lock
# file (and its temp files), the local config override, and each skill the
# lock names. Lines outside
# the block are kept as they are. A no-op outside --scope=project, and
# outside a git repo (a flake.nix-only project root).
sync_project_excludes() {
  [ "$install_scope" = "project" ] || return 0
  local common exclude lock name block current rest
  common=$(git -C "$project_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  [ -n "$common" ] || return 0
  exclude="$common/info/exclude"
  lock="$target_root/$PROJECT_LOCK_FILE"

  block="$EXCLUDE_BEGIN"$'\n'
  [ -n "${project_link:-}" ] && block+="/$project_link"$'\n'
  block+="/$project_suffix/$PROJECT_LOCK_FILE*"$'\n'
  block+="/$PROJECT_LOCAL_CONFIG"$'\n'
  if [ -f "$lock" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] && block+="/$project_suffix/$name"$'\n'
    done < <(jq -r '.skills // {} | keys[]' "$lock" 2>/dev/null || true)
  fi
  block+="$EXCLUDE_END"$'\n'

  current=""
  rest=""
  if [ -f "$exclude" ]; then
    current=$(awk -v b="$EXCLUDE_BEGIN" -v e="$EXCLUDE_END" \
      '$0==b{on=1} on{print} $0==e{on=0}' "$exclude")$'\n'
    rest=$(awk -v b="$EXCLUDE_BEGIN" -v e="$EXCLUDE_END" \
      '$0==b{on=1} !on{print} $0==e{on=0}' "$exclude")
  fi
  [ "$current" = "$block" ] && return 0

  mkdir -p "$common/info"
  {
    [ -n "$rest" ] && printf '%s\n' "$rest"
    printf '%s' "$block"
  } >"$exclude.tmp.$$"
  mv -f "$exclude.tmp.$$" "$exclude"
  printf 'excluded: %d path(s) this flake manages (in %s)\n' \
    "$(($(printf '%s' "$block" | wc -l) - 2))" "$exclude"
}

# Bring the project-scope layout into shape before install/reconcile write
# into $target_root. A no-op outside --scope=project. Returns 1 (after
# printing why) when the link path holds something it must not replace.
ensure_project_layout() {
  [ "$install_scope" = "project" ] || return 0
  local link_path="" link_dest=""
  if [ -n "${project_link:-}" ]; then
    link_path="$project_root/$project_link"
    link_dest=$(project_link_target)
    if [ -L "$link_path" ]; then
      if [ "$(readlink "$link_path")" != "$link_dest" ]; then
        if [ -d "$target_root" ] && [ "$(cd "$link_path" 2>/dev/null && pwd -P)" = "$(cd "$target_root" && pwd -P)" ]; then
          rm -f "$link_path"
        else
          move_project_link_aside "$link_path" "a symlink to $(readlink "$link_path")" || return 1
        fi
      fi
    elif [ -d "$link_path" ]; then
      migrate_project_link_dir "$link_path" || return 1
    elif [ -e "$link_path" ]; then
      move_project_link_aside "$link_path" "a file" || return 1
    fi
  fi

  mkdir -p "$target_root"
  if [ -n "$link_path" ]; then
    mkdir -p "$(dirname "$link_path")"
    ensure_symlink "$link_path" "$link_dest" 'linked'
  fi
  sync_project_excludes
}
