{ nixpkgs }:
let
  inherit (nixpkgs) lib;

  mkSkill =
    system:
    {
      name,
      src,
      version ? "0.1.0",
      description ? "Claude Code skill: ${name}",
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "claude-skill-${name}";
      inherit version src;
      dontBuild = true;
      installPhase = ''
        runHook preInstall
        install -Dm644 SKILL.md "$out/share/claude-skills/${name}/SKILL.md"
        for d in references scripts; do
          if [ -d "$d" ]; then
            mkdir -p "$out/share/claude-skills/${name}/$d"
            cp -r "$d/." "$out/share/claude-skills/${name}/$d/"
          fi
        done
        runHook postInstall
      '';
      meta = with pkgs.lib; {
        inherit description;
        license = licenses.asl20;
        platforms = platforms.unix;
      };
    };

  # A subdirectory of `skillsDir` is a "skill" iff it contains a SKILL.md.
  # Returns a sorted list of { name; src; } records.
  discoverSkills =
    skillsDir:
    let
      entries = builtins.readDir skillsDir;
      isDir = n: entries.${n} == "directory";
      hasSkillMd = n: builtins.pathExists (skillsDir + "/${n}/SKILL.md");
      dirNames = builtins.attrNames (lib.filterAttrs (n: _: isDir n) entries);
      skillNames = builtins.filter hasSkillMd dirNames;
    in
    map (n: {
      name = n;
      src = skillsDir + "/${n}";
    }) skillNames;

  # Bash-array body: one `"name:store_path"` line per skill, indented.
  skillsArrayBody =
    skills:
    if skills == [ ] then
      ""
    else
      lib.concatMapStringsSep "\n" (s: ''  "${s.name}:${s.drv}"'') skills;

  mkInstaller =
    system:
    {
      appName,
      skills,
      installRoot,
      envVarOverride,
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    pkgs.writeShellApplication {
      name = "install-${appName}";
      runtimeInputs = with pkgs; [
        coreutils
        nix
      ];
      text = ''
        target_root=''${${envVarOverride}:-${installRoot}}

        mode=symlink
        for arg in "$@"; do
          case "$arg" in
            --profile) mode=profile ;;
            -h|--help)
              cat <<EOF
        Usage: install-${appName} [--profile]

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
          ${envVarOverride}    override the install root (default: ${installRoot})
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

        declare -a skills_list=(
        ${skillsArrayBody skills}
        )

        mkdir -p "$target_root"

        case "$mode" in
          symlink)
            gcroots_dir=''${NIX_GCROOTS_DIR:-/nix/var/nix/gcroots/per-user/$USER}
            gcroots_ok=1
            if ! mkdir -p "$gcroots_dir" 2>/dev/null; then
              gcroots_ok=0
              printf 'WARNING: could not create %s; store paths may be GC-eligible\n' "$gcroots_dir" >&2
            fi
            for entry in "''${skills_list[@]}"; do
              skill_name=''${entry%%:*}
              store_path=''${entry#*:}
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
            done
            ;;

          profile)
            for entry in "''${skills_list[@]}"; do
              skill_name=''${entry%%:*}
              store_path=''${entry#*:}
              target="$target_root/$skill_name"
              if ! nix profile install "$store_path" 2>/dev/null; then
                printf 'Note: %s already in profile; use %s to bump it\n' "$skill_name" "'nix profile upgrade'" >&2
              fi
              profile_subpath="$HOME/.nix-profile/share/claude-skills/$skill_name"
              rm -rf "$target"
              ln -sfn "$profile_subpath" "$target"
              printf 'installed (profile): %s -> %s\n' "$target" "$profile_subpath"
            done
            printf 'manage with: nix profile list / upgrade / rollback / remove\n'
            ;;
        esac
      '';
    };

  mkPreview =
    system:
    {
      appName,
      displayName,
      skills,
      installRoot,
      envVarOverride,
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    pkgs.writeShellApplication {
      name = "preview-${appName}";
      runtimeInputs = with pkgs; [
        coreutils
        findutils
      ];
      text = ''
        target_root=''${${envVarOverride}:-${installRoot}}

        printf '%s preview (no changes made)\n\n' '${displayName}'
        printf 'Target directory: %s\n' "$target_root"
        printf '  (override with %s)\n\n' '${envVarOverride}'

        declare -a skills_list=(
        ${skillsArrayBody skills}
        )

        count=0
        for entry in "''${skills_list[@]}"; do
          skill_name=''${entry%%:*}
          store_path=''${entry#*:}
          skill_subpath="$store_path/share/claude-skills/$skill_name"
          size=$(du -shL "$skill_subpath" 2>/dev/null | cut -f1)
          printf '  %s  (%s)\n' "$skill_name" "$size"
          find -L "$skill_subpath" -mindepth 1 ! -type d | sed "s|^$skill_subpath/|      |"
          count=$((count + 1))
        done

        printf '\n%d skill(s) total.\n' "$count"
        printf '\nTo install (default — symlink + GC root):\n'
        printf "  nix run '.#install'\n"
        printf '\nTo install via nix profile (shows up in nix profile list):\n'
        printf "  nix run '.#install' -- --profile\n"
        printf '\n(preview only — no files were written)\n'
      '';
    };
in
{
  inherit
    mkSkill
    discoverSkills
    mkInstaller
    mkPreview
    ;
}
