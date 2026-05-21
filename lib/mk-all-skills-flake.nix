{
  nixpkgs,
  skillsDir,
  systems ? [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ],
  name ? "agent-skills-all",
  installRoot ? "$HOME/.claude/skills",
  envVarOverride ? "CLAUDE_SKILLS_DIR",
  # Prefix applied to each per-skill package attribute key, i.e.
  # `packages.<system>."${packagePrefix}${effectiveName}"`. Lets
  # multi-repo consumers brand their package keys (e.g. `"agent-skill-"`
  # or `"agent-skills-pack-"`) without overriding the convention per
  # skill. Affects only the package attribute key — not the installed
  # skill names, `pname`s, derivation names, or the aggregate `name`.
  packagePrefix ? "skill-",
  # Formula that derives each skill's effective name from a context
  # attrset (NOT a bare string), so a remapped name can encode where the
  # skill came from. Default is identity (no rename). The context is:
  #
  #   { name;                       # original discovered directory name
  #     source = {                  # the skill's origin repo (from `source`)
  #       owner; repo; url;
  #       rev; shortRev; dirty; narHash;
  #       lastModified;             # raw epoch seconds, passed through
  #       lastModifiedDate;         # "YYYY-MM-DD" (UTC)
  #       lastModifiedCompact; };   # "YYYYMMDD" (UTC)
  #     tooling = {                 # the flake-skills lineage that built it
  #       owner; repo; url; rev; shortRev; dirty; narHash; }; }
  #
  # `lastModifiedDate` / `lastModifiedCompact` are sliced from the
  # source's `lastModifiedDate` ("%Y%m%d%H%M%S", what Nix puts on
  # `self`); they are null unless `source.lastModifiedDate` is given.
  #
  # The result must satisfy Claude Code's name rule (^[a-z0-9-]{1,64}$),
  # asserted in mkSkill. Renaming is the supported fix for Claude Code's
  # flat skill namespace: e.g. `ctx: "${ctx.source.owner}-${ctx.name}"`
  # so vendored skills can't shadow built-ins or each other. The
  # pre-rename name is preserved in each skill's sentinel as
  # `originalSkillName`.
  renameFn ? (ctx: ctx.name),
  # The skills' origin repo, supplied by the consumer from their own
  # flake `self` (+ owner/repo). Only needed if `renameFn` references
  # `ctx.source.*`. Shape (all optional except as your formula needs):
  #   { owner; repo;            # or `url` (any git URL / flake ref —
  #                             #   host-agnostic, owner/repo best-effort)
  #     rev;                    # self.rev or self.dirtyRev
  #     shortRev;               # optional; derived from rev otherwise
  #     dirty; narHash;
  #     lastModified;           # self.lastModified (epoch, raw passthrough)
  #     lastModifiedDate; }     # self.lastModifiedDate ("%Y%m%d%H%M%S")
  source ? null,
  # Additional top-level directories from each discovered skill's source
  # to ship into the install alongside SKILL.md / references / scripts.
  # Applied uniformly to every discovered skill; missing dirs are
  # silently ignored per the standard posture. Same semantics as
  # mkSkill's `extraDirs`.
  extraDirs ? [ ],
  # Additional top-level files from each discovered skill's source to
  # ship at the install root. Each entry is a shell glob evaluated in
  # the skill's source (nullglob: no-match silently dropped). Applied
  # uniformly to every discovered skill. Use for upstream collections
  # whose SKILL.md files reference loose flat companion files (e.g.
  # `extraFiles = [ "*.md" "*.sh" "*.ts" "*.js" "*.dot" ]` covers every
  # loose-file case across obra/superpowers' 14 skills). Same semantics
  # as mkSkill's `extraFiles`.
  extraFiles ? [ ],
  # Injected by lib/default.nix from this flake's `self`. Same role as in
  # mk-skill-flake.nix.
  provenance,
}:
let
  internal = import ./internal.nix { inherit nixpkgs; };
  inherit (nixpkgs) lib;

  forAllSystems = f: lib.genAttrs systems (system: f system);

  discovered = internal.discoverSkills skillsDir;

  # Apply the rename formula once, here, so a single canonical post-rename
  # name flows into every downstream consumer — package keys, the
  # installer symlink, the GC root, the lock, and reconcile's "is this a
  # stray?" sweep. If the renamed name didn't propagate consistently,
  # reconcile would treat the install as undeclared and sweep it.
  renamed = map (
    s:
    let
      ctx = internal.mkRenameContext {
        inherit (s) name;
        inherit source;
        toolingProvenance = provenance;
      };
    in
    {
      name = renameFn ctx;
      originalName = s.name;
      inherit (s) src;
    }
  ) discovered;

  skillSetFor =
    system:
    map (s: {
      inherit (s) name;
      drv = internal.mkSkill system {
        inherit (s) name src;
        originalSkillName = s.originalName;
        inherit extraDirs extraFiles provenance;
      };
    }) renamed;

  aggregateFor =
    system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      skillSet = skillSetFor system;
    in
    pkgs.symlinkJoin {
      inherit name;
      paths = map (s: s.drv) skillSet;
    };

  installerFor =
    system:
    internal.mkInstaller system {
      appName = name;
      skills = skillSetFor system;
      inherit installRoot envVarOverride;
    };

  previewFor =
    system:
    internal.mkPreview system {
      appName = name;
      displayName = name;
      skills = skillSetFor system;
      inherit installRoot envVarOverride;
    };

  reapFor =
    system:
    internal.mkReap system {
      appName = name;
      inherit provenance installRoot envVarOverride;
    };

  uninstallFor =
    system:
    internal.mkUninstall system {
      appName = name;
      inherit provenance installRoot envVarOverride;
    };

  reconcileFor =
    system:
    internal.mkReconcile system {
      appName = name;
      skills = skillSetFor system;
      inherit provenance installRoot envVarOverride;
    };
in
{
  packages = forAllSystems (
    system:
    let
      # Prefix per-skill package keys with `packagePrefix` (default
      # `skill-`, matching mkSkillFlake's default) so bare skill names
      # like `nix-flakes` don't shadow same-named entries in nixpkgs or
      # aggregator flakes. The skill's user-facing identity (install
      # path, sentinel, slash command) still uses `s.name`.
      perSkill = lib.listToAttrs (
        map (s: {
          name = "${packagePrefix}${s.name}";
          value = s.drv;
        }) (skillSetFor system)
      );
    in
    perSkill
    // {
      default = aggregateFor system;
      agent-skills-all = aggregateFor system;
    }
  );

  apps = forAllSystems (system: {
    default = {
      type = "app";
      program = "${previewFor system}/bin/preview-${name}";
    };
    install = {
      type = "app";
      program = "${installerFor system}/bin/install-${name}";
    };
    uninstall = {
      type = "app";
      program = "${uninstallFor system}/bin/uninstall-${name}";
    };
    preview = {
      type = "app";
      program = "${previewFor system}/bin/preview-${name}";
    };
    reap = {
      type = "app";
      program = "${reapFor system}/bin/reap-${name}";
    };
    reconcile = {
      type = "app";
      program = "${reconcileFor system}/bin/reconcile-${name}";
    };
  });
}
