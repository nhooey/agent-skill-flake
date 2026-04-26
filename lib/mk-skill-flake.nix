{
  nixpkgs,
  skillName,
  # Nix-flake package attribute name. Defaults to `skillName`; override when the
  # skill's name shadows a common CLI (e.g. `git`) so the flake's
  # `packages.<system>.<name>` won't collide with packages of the same name in
  # nixpkgs or in aggregator flakes re-exporting multiple skills. Does NOT
  # affect the user-facing skill identity (slash command, install path,
  # binary names) — those continue to use `skillName`.
  packageName ? skillName,
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
  # Injected by lib/default.nix from this flake's `self`. Bakes into the
  # skill's sentinel so reconcile/reap can scope to "things I built".
  provenance,
}:
let
  internal = import ./internal.nix { inherit nixpkgs; };

  forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

  skillFor =
    system:
    internal.mkSkill system {
      name = skillName;
      inherit src version description provenance;
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
    ${packageName} = skillFor system;
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
