# Build the lookup table of available skill names for subset filtering
# and typo protection.
declare -a all_skill_names=()
declare -A skill_path_by_name=()
for entry in "${skills_list[@]}"; do
  parse_skill_entry "$entry"
  all_skill_names+=("$skill_name")
  skill_path_by_name["$skill_name"]="$store_path"
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
if wants_help "$@"; then
  print_help
  exit 0
fi

parse_scope_args "$@" || exit $?
set -- "${scope_remaining_args[@]}"

mode=symlink
declare -a selected_names=()
for arg in "$@"; do
  case "$arg" in
  --profile) mode=profile ;;
  -*)
    usage_error "unknown flag: $arg"
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
    parse_skill_entry "$entry"
    target="$target_root/$skill_name"
    gcroot_target="${gcroots_dir}/${GC_ROOT_PREFIX}${skill_name}"

    ensure_symlink "$target" "$skill_subpath" 'installed (symlink)'

    if [ "$gcroots_ok" = "1" ] &&
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
    parse_skill_entry "$entry"
    target="$target_root/$skill_name"
    if ! nix profile install "$store_path" 2>/dev/null; then
      printf 'Note: %s already in profile; use %s to bump it\n' "$skill_name" "'nix profile upgrade'" >&2
    fi
    profile_subpath="${HOME}/.nix-profile/${SKILLS_SHARE_SUBDIR}/${skill_name}"
    rm -rf "$target"
    ln -sfn "$profile_subpath" "$target"
    printf 'installed (profile): %s -> %s\n' "$target" "$profile_subpath"
    lock_upsert "$skill_name" "$store_path"
  done
  printf 'manage with: nix profile list / upgrade / rollback / remove\n'
  ;;
esac
