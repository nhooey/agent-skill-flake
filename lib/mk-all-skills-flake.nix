{
  nixpkgs,
  skillsDir,
  # Systems to fan out over. Defaults to `defaultSystems` (the
  # `nix-systems/default` flake input injected by lib/default.nix) rather
  # than a hardcoded platform list, so downstream consumers retarget the
  # fanout by overriding the `systems` input instead of forking. Pass an
  # explicit list or `import <your systems input>` to override per call.
  systems ? defaultSystems,
  name ? "agent-skills-all",
  # Which agent's filesystem layout to target. Each profile in
  # lib/agent-profiles.nix names a per-scope install suffix
  # (`$HOME/<personalSuffix>` for personal scope,
  # `<project-root>/<projectSuffix>` for project scope). Currently
  # supports `claude-code`, `codex`, `cursor`. Throws at eval if the
  # name isn't a known profile.
  agent ? "claude-code",
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
  # Injected by lib/default.nix from this flake's `nix-systems/default`
  # input; the default value of `systems` above.
  defaultSystems,
}:
let
  internal = import ./internal.nix { inherit nixpkgs; };
  inherit (nixpkgs) lib;

  profile = internal.resolveAgentProfile agent;

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
      rename = internal.applyRename {
        inherit (s) name;
        inherit source provenance renameFn;
      };
    in
    {
      name = rename.effective;
      originalName = rename.original;
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
      inherit profile;
    };

  previewFor =
    system:
    internal.mkPreview system {
      appName = name;
      displayName = name;
      skills = skillSetFor system;
      inherit profile;
    };

  reapFor =
    system:
    internal.mkReap system {
      appName = name;
      inherit provenance profile;
    };

  uninstallFor =
    system:
    internal.mkUninstall system {
      appName = name;
      inherit provenance profile;
    };

  reconcileFor =
    system:
    internal.mkReconcile system {
      appName = name;
      skills = skillSetFor system;
      inherit provenance profile;
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

  # The declarative dev-shell one-liner: converge the target to this pack's
  # declared skill set at `--scope=project`. Only reconcile removes strays, so
  # the shell stays a pure function of the inputs. Mirrors mkAggregateSkillsFlake's
  # `reconcileScript` so consumers can drop either into a devshell startup hook
  # without reaching into `apps.reconcile.program` and appending the scope flag.
  reconcileScript = system: "${reconcileFor system}/bin/reconcile-${name} --scope=project";
}
