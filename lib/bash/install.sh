mode=symlink
for arg in "$@"; do
  case "$arg" in
    --profile) mode=profile ;;
    -h|--help)
      cat <<EOF
Usage: $app_name [--profile]

Default (symlink mode):
  For each skill, creates a symlink at \$target_root/<skill> pointing
  to its content under the Nix store, and registers a per-user GC root
  so the store path is protected from \`nix-store --gc\`.

--profile:
  Installs each skill into your Nix profile (\`nix profile install\`),
  then symlinks \$target_root/<skill> into
  ~/.nix-profile/share/claude-skills/. Skills then appear in
  \`nix profile list\` and support \`nix profile upgrade\` / rollback.

Environment:
  $env_var_name    override the install root (default: $install_root_default)
  NIX_GCROOTS_DIR    override the GC-roots dir (default: per-user dir)

Currently installed target root: $target_root
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Try '--help'." >&2
      exit 2
      ;;
  esac
done

mkdir -p "$target_root"

case "$mode" in
  symlink)
    gcroots_dir=${NIX_GCROOTS_DIR:-/nix/var/nix/gcroots/per-user/$USER}
    gcroots_ok=1
    if ! mkdir -p "$gcroots_dir" 2>/dev/null; then
      gcroots_ok=0
      printf 'WARNING: could not create %s; store paths may be GC-eligible\n' "$gcroots_dir" >&2
    fi
    for entry in "${skills_list[@]}"; do
      skill_name=${entry%%:*}
      store_path=${entry#*:}
      skill_subpath="$store_path/share/claude-skills/$skill_name"
      target="$target_root/$skill_name"
      rm -rf "$target"
      ln -sfn "$skill_subpath" "$target"
      printf 'installed (symlink): %s -> %s\n' "$target" "$skill_subpath"
      if [ "$gcroots_ok" = "1" ]; then
        if ln -sfn "$store_path" "$gcroots_dir/claude-skill-$skill_name" 2>/dev/null; then
          printf 'GC root: %s -> %s\n' "$gcroots_dir/claude-skill-$skill_name" "$store_path"
        else
          printf 'WARNING: could not write GC root for %s; store path may be GC-eligible\n' "$skill_name" >&2
        fi
      fi
      lock_upsert "$skill_name" "$store_path"
    done
    ;;

  profile)
    for entry in "${skills_list[@]}"; do
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
