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
      runtimeInputs = with pkgs; [ coreutils ];
      text = ''
        target_root=''${${envVarOverride}:-${installRoot}}
        target="$target_root/${skillName}"
        mkdir -p "$target_root"
        rm -rf "$target"
        cp -rL ${skill}/share/claude-skills/${skillName} "$target"
        chmod -R u+w "$target"
        printf 'installed %s -> %s\n' "${skillName}" "$target"
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
        printf 'Would install to: %s\n' "$target"
        printf '  (override with %s)\n\n' '${envVarOverride}'
        printf 'Files:\n'
        find -L "$src" -mindepth 1 ! -type d | sed "s|^$src/|  |"
        printf '\nTo install, run:\n'
        printf "  nix run '.#install'\n"
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
