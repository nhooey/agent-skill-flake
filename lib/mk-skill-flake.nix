{
  nixpkgs,
  skillName,
  # Nix-flake package attribute name. When null, defaults to
  # `"${packagePrefix}${effectiveName}"` (the post-rename name) so
  # `packages.<system>.<name>` is collision-safe by construction — bare
  # skill names (`git`, `nix-flakes`, …) routinely shadow same-named
  # entries in nixpkgs or in aggregator flakes re-exporting multiple
  # skills. Override only if you have a specific reason to deviate from
  # the `<prefix><name>` convention.
  packageName ? null,
  # Prefix applied to the default package attribute key, i.e. the key
  # becomes `"${packagePrefix}${effectiveName}"`. Lets multi-repo
  # consumers brand their package keys (e.g. `"agent-skill-"`) without
  # having to set `packageName` per skill. Ignored when `packageName`
  # is set explicitly (`packageName` wins). Affects only the package
  # attribute key — not the installed skill name, `pname`, or the
  # derivation name.
  packagePrefix ? "skill-",
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
  # Additional top-level files from `src` to ship at the install root.
  # Each entry is a shell glob evaluated in `src` (nullglob: no-match
  # silently dropped). Matches that resolve to directories are skipped —
  # use `extraDirs` for those. Use for upstream skills whose SKILL.md
  # cross-references loose flat files (e.g. obra/superpowers'
  # `visual-companion.md`, `code-reviewer.md`) that the strict
  # SKILL.md + references/ + scripts/ whitelist would otherwise drop.
  extraFiles ? [ ],
  # Which agent's filesystem layout to target. Each profile in
  # lib/agent-profiles.nix names a per-scope install suffix
  # (`$HOME/<personalSuffix>` for personal scope,
  # `<project-root>/<projectSuffix>` for project scope). Currently
  # supports `claude-code`, `codex`, `cursor`. Throws at eval if the
  # name isn't a known profile.
  agent ? "claude-code",
  # Injected by lib/default.nix from this flake's `self`. Bakes into the
  # skill's sentinel so reconcile/reap can scope to "things I built".
  provenance,
}:
let
  internal = import ./internal.nix { inherit nixpkgs; };

  profile = internal.resolveAgentProfile agent;

  forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

  # The skill's effective identity after the rename formula. Used for the
  # install path, sentinel `skillName`, default package key, and the
  # preview/uninstall default — everything user-facing. `skillName`
  # itself is kept only as the pre-rename `originalSkillName`.
  effectiveName = renameFn (
    internal.mkRenameContext {
      name = skillName;
      inherit source;
      toolingProvenance = provenance;
    }
  );

  effectivePackageName =
    if packageName == null then "${packagePrefix}${effectiveName}" else packageName;

  skillFor =
    system:
    internal.mkSkill system {
      name = effectiveName;
      originalSkillName = skillName;
      inherit
        src
        version
        description
        extraDirs
        extraFiles
        provenance
        ;
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
      inherit profile;
    };

  previewFor =
    system:
    internal.mkPreview system {
      appName = skillName;
      displayName = effectiveName;
      skills = skillsFor system;
      inherit profile;
    };

  reapFor =
    system:
    internal.mkReap system {
      appName = skillName;
      inherit provenance profile;
    };

  uninstallFor =
    system:
    internal.mkUninstall system {
      appName = skillName;
      defaultSkillName = effectiveName;
      inherit provenance profile;
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
