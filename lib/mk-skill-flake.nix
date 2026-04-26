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
  internal = import ./internal.nix { inherit nixpkgs; };

  forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

  skillFor =
    system:
    internal.mkSkill system {
      name = skillName;
      inherit src version description;
    };

  skillsFor = system: [
    {
      name = skillName;
      drv = skillFor system;
    }
  ];

  installerFor =
    system:
    internal.mkInstaller system {
      appName = skillName;
      skills = skillsFor system;
      inherit installRoot envVarOverride;
    };

  previewFor =
    system:
    internal.mkPreview system {
      appName = skillName;
      displayName = skillName;
      skills = skillsFor system;
      inherit installRoot envVarOverride;
    };
in
{
  packages = forAllSystems (system: {
    default = skillFor system;
    ${skillName} = skillFor system;
  });

  apps = forAllSystems (system: {
    default = {
      type = "app";
      program = "${previewFor system}/bin/preview-${skillName}";
    };
    install = {
      type = "app";
      program = "${installerFor system}/bin/install-${skillName}";
    };
    preview = {
      type = "app";
      program = "${previewFor system}/bin/preview-${skillName}";
    };
  });
}
