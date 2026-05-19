{
  nixpkgs,
  skillName,
  # Nix-flake package attribute name. When null, defaults to
  # `"skill-${effectiveName}"` (the post-rename name) so
  # `packages.<system>.<name>` is collision-safe by construction — bare
  # skill names (`git`, `nix-flakes`, …) routinely shadow same-named
  # entries in nixpkgs or in aggregator flakes re-exporting multiple
  # skills. Override only if you have a specific reason to deviate from
  # the `skill-*` convention.
  packageName ? null,
  # Optional rename formula, same shape/context as mkAllSkillsFlake's
  # `renameFn` (see that file for the full context attrset). For a single
  # skill `ctx.name` is `skillName`. Default is identity. The result is
  # the skill's real identity: install path, slash command, sentinel
  # `skillName`, and (when `packageName` is null) the package key. The
  # pre-rename `skillName` is kept in the sentinel as `originalSkillName`.
  renameFn ? (ctx: ctx.name),
  # The skill's origin repo, for `renameFn`'s `ctx.source.*`. Supplied by
  # the consumer from their flake `self` (+ owner/repo). See
  # mk-all-skills-flake.nix for the accepted shape.
  source ? null,
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

  # The skill's effective identity after the rename formula. Used for the
  # install path, sentinel `skillName`, default package key, and the
  # preview/uninstall default — everything user-facing. `skillName`
  # itself is kept only as the pre-rename `originalSkillName`.
  effectiveName = renameFn (internal.mkRenameContext {
    name = skillName;
    inherit source;
    toolingProvenance = provenance;
  });

  effectivePackageName =
    if packageName == null then "skill-${effectiveName}" else packageName;

  skillFor =
    system:
    internal.mkSkill system {
      name = effectiveName;
      originalSkillName = skillName;
      inherit src version description extraDirs provenance;
    };

  skillsFor = system: [
    {
      name = effectiveName;
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
      displayName = effectiveName;
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
      defaultSkillName = effectiveName;
      inherit provenance installRoot envVarOverride;
    };
in
{
  packages = forAllSystems (system: {
    default = skillFor system;
    ${effectivePackageName} = skillFor system;
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
