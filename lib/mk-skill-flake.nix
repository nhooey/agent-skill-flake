{
  nixpkgs,
  skillName,
  # Nix-flake package attribute name. Defaults to `"skill-${skillName}"` so
  # `packages.<system>.<name>` is collision-safe by construction — bare
  # skill names (`git`, `nix-flakes`, …) routinely shadow same-named entries
  # in nixpkgs or in aggregator flakes re-exporting multiple skills. Override
  # only if you have a specific reason to deviate from the `skill-*`
  # convention. Does NOT affect the user-facing skill identity (slash
  # command, install path, binary names) — those continue to use `skillName`.
  packageName ? "skill-${skillName}",
  src,
  systems ? [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ],
  description ? "Claude Code skill: ${skillName}",
  version ? "0.1.0",
  # Additional top-level directories from `src` to ship into the install
  # alongside SKILL.md / references / scripts. Use for upstream skills with
  # non-standard layouts. Empty list keeps the strict default surface.
  extraDirs ? [ ],
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
      inherit src version description extraDirs provenance;
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

  reapFor =
    system:
    internal.mkReap system {
      appName = skillName;
      inherit provenance installRoot envVarOverride;
    };

  uninstallFor =
    system:
    internal.mkUninstall system {
      appName = skillName;
      defaultSkillName = skillName;
      inherit provenance installRoot envVarOverride;
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
    uninstall = {
      type = "app";
      program = "${uninstallFor system}/bin/uninstall-${skillName}";
    };
    preview = {
      type = "app";
      program = "${previewFor system}/bin/preview-${skillName}";
    };
    reap = {
      type = "app";
      program = "${reapFor system}/bin/reap-${skillName}";
    };
  });
}
