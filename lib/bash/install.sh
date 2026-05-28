# Build the lookup table of available skill names for subset filtering
# and typo protection.
declare -a all_skill_names=()
declare -A skill_path_by_name=()
for entry in "${skills_list[@]}"; do
  name=${entry%%:*}
  path=${entry#*:}
  all_skill_names+=("$name")
  skill_path_by_name["$name"]="$path"
done

print_help() {
  cat <<EOF
Usage: $app_name --scope=<personal|project|custom> [--root=<path>] \\
                 [--gcroots-dir=<path>] [--profile] [<skill-name>...]

Required:
  --scope=personal              Install under \$HOME/$personal_suffix
  --scope=project               Install under <project-root>/$project_suffix
                                (project root = nearest .git/ or flake.nix
                                ancestor of \$PWD)
  --scope=custom --root=<path>  Install under <path>

Optional:
  --gcroots-dir=<path>          Override per-user GC-roots dir
                                (default: /nix/var/nix/gcroots/per-user/\$USER)
  --profile                     Install via \`nix profile install\` and
                                symlink to ~/.nix-profile/share/claude-skills/
                                instead of the default direct-symlink mode.
  -h, --help                    Show this help and exit.

Positional <skill-name>...:
  If given, install only those skills (must match names exposed by this
  flake). With no positional args, install every skill in the flake.

Default (symlink mode):
  For each skill, creates a symlink at <target>/<skill> pointing to its
  content under the Nix store, and registers a per-user GC root so the
  store path is protected from \`nix-store --gc\`.

--profile:
  Installs each skill into your Nix profile (\`nix profile install\`),
  then symlinks <target>/<skill> into ~/.nix-profile/share/claude-skills/.
  Skills then appear in \`nix profile list\` and support
  \`nix profile upgrade\` / rollback.

Available skills:
EOF
  for n in "${all_skill_names[@]}"; do
    printf '  %s\n' "$n"
  done
}

# --help short-circuits before scope parsing so the help text is
# obtainable without picking a scope.
for arg in "$@"; do
  case "$arg" in
    -h|--help) print_help; exit 0 ;;
  esac
done

parse_scope_args "$@" || exit $?
set -- "${scope_remaining_args[@]}"

mode=symlink
declare -a selected_names=()
for arg in "$@"; do
  case "$arg" in
    --profile) mode=profile ;;
    -*)
      printf '%s: unknown flag: %s\n' "$app_name" "$arg" >&2
      printf '  See `%s --help` for usage.\n' "$app_name" >&2
      exit 2
      ;;
    *) selected_names+=("$arg") ;;
  esac
done

# Subset filter. Unknown names are a hard error — the eval-time
# equivalent for build-time skill discovery.
declare -a effective_skills=()
if [ ${#selected_names[@]} -gt 0 ]; then
  for want in "${selected_names[@]}"; do
    if [ -z "${skill_path_by_name[$want]+x}" ]; then
      printf '%s: unknown skill name: %s\n' "$app_name" "$want" >&2
      printf '  Available skills:\n' >&2
      for n in "${all_skill_names[@]}"; do
        printf '    %s\n' "$n" >&2
      done
      exit 2
    fi
    effective_skills+=("$want:${skill_path_by_name[$want]}")
  done
else
  effective_skills=("${skills_list[@]}")
fi

mkdir -p "$target_root"

case "$mode" in
  symlink)
    gcroots_ok=1
    if ! mkdir -p "$gcroots_dir" 2>/dev/null; then
      gcroots_ok=0
      printf 'WARNING: could not create %s; store paths may be GC-eligible\n' "$gcroots_dir" >&2
    fi
    for entry in "${effective_skills[@]}"; do
      skill_name=${entry%%:*}
      store_path=${entry#*:}
      skill_subpath="$store_path/share/claude-skills/$skill_name"
      target="$target_root/$skill_name"
      gcroot_target="$gcroots_dir/claude-skill-$skill_name"

      # Direct `readlink` (no `-f`): we want the symlink's literal
      # target, not the fully-resolved path. Equal → state already
      # matches → skip the rm/ln/printf and stay silent. Missing,
      # non-symlink, or wrong-target → fall through to rewrite.
      if [ "$(readlink "$target" 2>/dev/null)" != "$skill_subpath" ]; then
        rm -rf "$target"
        ln -sfn "$skill_subpath" "$target"
        printf 'installed (symlink): %s -> %s\n' "$target" "$skill_subpath"
      fi

      if [ "$gcroots_ok" = "1" ] && \
         [ "$(readlink "$gcroot_target" 2>/dev/null)" != "$store_path" ]; then
        if ln -sfn "$store_path" "$gcroot_target" 2>/dev/null; then
          printf 'GC root: %s -> %s\n' "$gcroot_target" "$store_path"
        else
          printf 'WARNING: could not write GC root for %s; store path may be GC-eligible\n' "$skill_name" >&2
        fi
      fi

      lock_upsert "$skill_name" "$store_path"
    done
    ;;

  profile)
    for entry in "${effective_skills[@]}"; do
      skill_name=${entry%%:*}
      store_path=${entry#*:}
      target="$target_root/$skill_name"
      if ! nix profile install "$store_path" 2>/dev/null; then
        printf 'Note: %s already in profile; use %s to bump it\n' "$skill_name" "'nix profile upgrade'" >&2
      fi
      profile_subpath="$HOME/.nix-profile/share/claude-skills/$skill_name"
      rm -rf "$target"
      ln -sfn "$profile_subpath" "$target"
      printf 'installed (profile): %s -> %s\n' "$target" "$profile_subpath"
      lock_upsert "$skill_name" "$store_path"
    done
    printf 'manage with: nix profile list / upgrade / rollback / remove\n'
    ;;
esac
