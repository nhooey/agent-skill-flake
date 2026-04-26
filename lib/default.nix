{
  nixpkgs,
  skillName,
  src,
  systems ? [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ],
  description ? "Claude Code skill: ${skillName}",
  version ? "0.1.0",
  installRoot ? "$HOME/.claude/skills",
  envVarOverride ? "CLAUDE_SKILLS_DIR",
}:
let
  forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

  mkSkill =
    system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "claude-skill-${skillName}";
      inherit version src;
      dontBuild = true;
      installPhase = ''
        runHook preInstall
        install -Dm644 SKILL.md "$out/share/claude-skills/${skillName}/SKILL.md"
        for d in references scripts; do
          if [ -d "$d" ]; then
            mkdir -p "$out/share/claude-skills/${skillName}/$d"
            cp -r "$d/." "$out/share/claude-skills/${skillName}/$d/"
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

  mkInstaller =
    system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      skill = mkSkill system;
    in
    pkgs.writeShellApplication {
      name = "install-${skillName}";
      runtimeInputs = with pkgs; [
        coreutils
        nix
      ];
      text = ''
        target_root=''${${envVarOverride}:-${installRoot}}
        target="$target_root/${skillName}"
        store_path=${skill}
        skill_subpath="$store_path/share/claude-skills/${skillName}"

        mode=symlink
        for arg in "$@"; do
          case "$arg" in
            --profile) mode=profile ;;
            -h|--help)
              cat <<EOF
        Usage: install-${skillName} [--profile]

        Default (symlink mode):
          Symlinks $target -> the skill content under the Nix store, and
          registers a per-user GC root so the store path is protected from
          \`nix-store --gc\`.

        --profile:
          Installs the skill into your Nix profile (\`nix profile install\`),
          then symlinks $target into ~/.nix-profile/share/claude-skills/.
          Skills then appear in \`nix profile list\` and support
          \`nix profile upgrade\` / \`rollback\`.

        Environment:
          ${envVarOverride}    override the install root (default: ${installRoot})
          NIX_GCROOTS_DIR    override the GC-roots dir (default: per-user dir)
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
        rm -rf "$target"

        case "$mode" in
          symlink)
            ln -sfn "$skill_subpath" "$target"

            gcroots_dir=''${NIX_GCROOTS_DIR:-/nix/var/nix/gcroots/per-user/$USER}
            if mkdir -p "$gcroots_dir" 2>/dev/null && \
               ln -sfn "$store_path" "$gcroots_dir/claude-skill-${skillName}" 2>/dev/null; then
              printf 'installed (symlink): %s -> %s\n' "$target" "$skill_subpath"
              printf 'GC root: %s -> %s\n' "$gcroots_dir/claude-skill-${skillName}" "$store_path"
            else
              printf 'installed (symlink): %s -> %s\n' "$target" "$skill_subpath"
              printf 'WARNING: could not write GC root to %s; store path may be GC-eligible\n' "$gcroots_dir" >&2
            fi
            ;;

          profile)
            if ! nix profile install "$store_path" 2>/dev/null; then
              printf 'Note: skill already in profile; use %s to bump it\n' "'nix profile upgrade'" >&2
            fi
            profile_subpath="$HOME/.nix-profile/share/claude-skills/${skillName}"
            ln -sfn "$profile_subpath" "$target"
            printf 'installed (profile): %s -> %s\n' "$target" "$profile_subpath"
            printf 'manage with: nix profile list / upgrade / rollback / remove\n'
            ;;
        esac
      '';
    };

  mkPreview =
    system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      skill = mkSkill system;
    in
    pkgs.writeShellApplication {
      name = "preview-${skillName}";
      runtimeInputs = with pkgs; [
        coreutils
        findutils
      ];
      text = ''
        target_root=''${${envVarOverride}:-${installRoot}}
        target="$target_root/${skillName}"
        src=${skill}/share/claude-skills/${skillName}
        printf '%s preview (no changes made)\n\n' '${skillName}'
        printf 'Would symlink: %s -> %s\n' "$target" "$src"
        printf '  (override target root with %s)\n\n' '${envVarOverride}'
        printf 'Files (read-only via the symlink target):\n'
        find -L "$src" -mindepth 1 ! -type d | sed "s|^$src/|  |"
        printf '\nTo install (default — symlink + GC root):\n'
        printf "  nix run '.#install'\n"
        printf '\nTo install via nix profile (shows up in nix profile list):\n'
        printf "  nix run '.#install' -- --profile\n"
        printf '\n(preview only — no files were written)\n'
      '';
    };
in
{
  packages = forAllSystems (system: {
    default = mkSkill system;
    ${skillName} = mkSkill system;
  });

  apps = forAllSystems (system: {
    default = {
      type = "app";
      program = "${mkPreview system}/bin/preview-${skillName}";
    };
    install = {
      type = "app";
      program = "${mkInstaller system}/bin/install-${skillName}";
    };
    preview = {
      type = "app";
      program = "${mkPreview system}/bin/preview-${skillName}";
    };
  });
}
