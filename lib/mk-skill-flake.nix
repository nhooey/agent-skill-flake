{
  nixpkgs,
  skillName,
  # Nix-flake package attribute name. When null, defaults to the composed
  # `"<packagePrefix><namespace>-<effectiveName>"` key (see `namespaceFn`)
  # so `packages.<system>.<name>` is collision-safe by construction — bare
  # skill names (`git`, `nix-flakes`, …) routinely shadow same-named
  # entries in nixpkgs or in aggregator flakes re-exporting multiple
  # skills. Override only to deviate from the convention.
  packageName ? null,
  # Category prefix on the default package attribute key, before the owner
  # namespace segment: `"<packagePrefix><namespace>-<effectiveName>"`. null
  # uses the library default (`agent-skill-`). Ignored when `packageName`
  # is set (`packageName` wins). Affects only the package attribute key —
  # not the installed skill name, `pname`, or the derivation name.
  packagePrefix ? null,
  # Owner namespace segment spliced into the package key, as a formula over
  # the same `ctx` as `renameFn` (default `ctx: ctx.source.owner`). A
  # non-empty result yields `<packagePrefix><segment>-<effectiveName>`;
  # `""` omits the segment; `null` (e.g. the default with no derivable
  # owner) is a hard eval error — pass `source` with an owner, return a
  # string, or return `""` on purpose. Like `packagePrefix`, it touches
  # only the package key, not the installed skill name. Ignored when
  # `packageName` is set.
  namespaceFn ? (ctx: ctx.source.owner),
  # Optional rename formula, same shape/context as mkAllSkillsFlake's
  # `renameFn` (see that file for the full context attrset). For a single
  # skill `ctx.name` is `skillName`. Default is identity. The result is
  # the skill's real identity: install path, slash command, sentinel
  # `skillName`, and (when `packageName` is null) the package key. The
  # pre-rename `skillName` is kept in the sentinel as `originalSkillName`.
  renameFn ? (ctx: ctx.name),
  # The skill's origin repo, for `renameFn`'s and `namespaceFn`'s
  # `ctx.source.*`. Supplied by the consumer from their flake `self`
  # (+ owner/repo). See mk-all-skills-flake.nix for the accepted shape.
  source ? null,
  src,
  # Systems to fan out over. Defaults to `defaultSystems` (the
  # `nix-systems/default` flake input injected by lib/default.nix) rather
  # than a hardcoded platform list, so downstream consumers retarget the
  # fanout by overriding the `systems` input instead of forking. Pass an
  # explicit list or `import <your systems input>` to override per call.
  systems ? defaultSystems,
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
  # Injected by lib/default.nix from this flake's `nix-systems/default`
  # input; the default value of `systems` above.
  defaultSystems,
}:
let
  internal = import ./internal.nix { inherit nixpkgs; };

  profile = internal.resolveAgentProfile agent;

  forAllSystems = internal.forAllSystems systems;

  # Rename + namespace + key resolution in one place (shared with
  # mkAllSkillsFlake). `effective` is the skill's user-facing identity
  # (install path, sentinel `skillName`, preview/uninstall default);
  # `skillName` is kept only as the pre-rename `originalSkillName`.
  naming = internal.resolveSkillNaming {
    name = skillName;
    packagePrefix = if packagePrefix == null then internal.defaultPackagePrefix else packagePrefix;
    inherit
      source
      provenance
      renameFn
      namespaceFn
      ;
  };
  effectiveName = naming.effective;

  effectivePackageName = if packageName == null then naming.key else packageName;

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

  purgeFor =
    system:
    internal.mkPurge system {
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

  apps = forAllSystems (
    system:
    internal.mkAppSuite {
      name = skillName;
      default = true;
      programs = {
        install = installerFor system;
        uninstall = uninstallFor system;
        preview = previewFor system;
        reap = reapFor system;
        purge = purgeFor system;
      };
    }
  );
}
