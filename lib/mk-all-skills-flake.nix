{
  nixpkgs,
  skillsDir,
  # Systems to fan out over. Defaults to `defaultSystems` (the
  # `nix-systems/default` flake input injected by lib/default.nix) rather
  # than a hardcoded platform list, so downstream consumers retarget the
  # fanout by overriding the `systems` input instead of forking. Pass an
  # explicit list or `import <your systems input>` to override per call.
  systems ? defaultSystems,
  # Package attribute key (and reconcile-ownership appName) of the
  # aggregate "all" bundle. null derives `agent-skills-<owner>-all` from
  # the resolved namespace (`agent-skills-all` when the namespace is "").
  name ? null,
  # Which agent's filesystem layout to target. Each profile in
  # lib/agent-profiles.nix names a per-scope install suffix
  # (`$HOME/<personalSuffix>` for personal scope,
  # `<project-root>/<projectSuffix>` for project scope). Currently
  # supports `claude-code`, `codex`, `cursor`. Throws at eval if the
  # name isn't a known profile.
  agent ? "claude-code",
  # Category prefix on each per-skill package attribute key, before the
  # owner namespace segment and the skill name:
  # `packages.<system>."<packagePrefix><namespace>-<effectiveName>"`. null
  # uses the library default (`agent-skill-`). Affects only the package
  # attribute key — not the installed skill names, `pname`s, derivation
  # names, or the aggregate `name`.
  packagePrefix ? null,
  # Owner namespace segment spliced into every per-skill package key, as a
  # formula over the same `ctx` as `renameFn` (default
  # `ctx: ctx.source.owner`). A non-empty result yields
  # `<packagePrefix><segment>-<effectiveName>` and `agent-skills-<segment>-all`
  # for the aggregate; `""` omits the segment; `null` (the default with no
  # derivable owner) is a hard eval error — pass `source` with an owner,
  # return a string, or return `""` on purpose. Touches only package keys
  # and the aggregate `name`, never the installed skill names.
  namespaceFn ? (ctx: ctx.source.owner),
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
  #     tooling = {                 # the agent-skill-flake lineage that built it
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
  # flake `self` (+ owner/repo). The default `namespaceFn` reads
  # `ctx.source.owner` from it, so a hosted source is the no-friction
  # path; an unset/local/ownerless source makes the namespace null (a
  # hard error unless `namespaceFn` returns a string or ""). Also feeds
  # `renameFn`'s `ctx.source.*`. Shape (all optional except as needed):
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

  forAllSystems = internal.forAllSystems systems;

  discovered = internal.discoverSkills skillsDir;

  pp = if packagePrefix == null then internal.defaultPackagePrefix else packagePrefix;

  # The aggregate "all" bundle's owner namespace, resolved once from the
  # source (the default `namespaceFn` ignores the per-skill name). Drives
  # the plural `agent-skills-<namespace>-all` key/appName.
  aggNamespace = internal.resolveNamespace {
    inherit namespaceFn;
    ctx = internal.mkRenameContext {
      name = "all";
      inherit source;
      toolingProvenance = provenance;
    };
  };
  aggName =
    if name != null then
      name
    else if aggNamespace == "" then
      "agent-skills-all"
    else
      "agent-skills-${aggNamespace}-all";

  # Resolve rename + namespace + package key once per discovered skill, so
  # one canonical post-rename name and key flow into every downstream
  # consumer — package keys, the installer symlink, the GC root, the lock,
  # and reconcile's "is this a stray?" sweep. If the renamed name didn't
  # propagate consistently, reconcile would treat the install as undeclared
  # and sweep it.
  renamed = map (
    s:
    let
      naming = internal.resolveSkillNaming {
        inherit (s) name;
        packagePrefix = pp;
        inherit
          source
          provenance
          renameFn
          namespaceFn
          ;
      };
    in
    {
      name = naming.effective;
      key = naming.key;
      originalName = naming.original;
      inherit (s) src;
    }
  ) discovered;

  skillSetFor =
    system:
    map (s: {
      inherit (s) name key;
      drv = internal.mkSkill system {
        inherit (s) name src;
        originalSkillName = s.originalName;
        inherit extraDirs extraFiles provenance;
      };
    }) renamed;

  # The skill set, guarded against a `renameFn` collapsing two skills onto
  # one install name. Every install/aggregate consumer draws from this.
  checkedSkillSetFor =
    system:
    internal.assertUniqueSkillNames {
      label = "mkAllSkillsFlake pack '${aggName}'";
      skills = skillSetFor system;
    };

  aggregateFor =
    system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    pkgs.symlinkJoin {
      name = aggName;
      paths = map (s: s.drv) (checkedSkillSetFor system);
    };

  installerFor =
    system:
    internal.mkInstaller system {
      appName = aggName;
      skills = checkedSkillSetFor system;
      inherit profile;
    };

  previewFor =
    system:
    internal.mkPreview system {
      appName = aggName;
      displayName = aggName;
      skills = checkedSkillSetFor system;
      inherit profile;
    };

  reapFor =
    system:
    internal.mkReap system {
      appName = aggName;
      inherit provenance profile;
    };

  purgeFor =
    system:
    internal.mkPurge system {
      appName = aggName;
      inherit provenance profile;
    };

  uninstallFor =
    system:
    internal.mkUninstall system {
      appName = aggName;
      inherit provenance profile;
    };

  reconcileFor =
    system:
    internal.mkReconcile system {
      appName = aggName;
      skills = checkedSkillSetFor system;
      inherit provenance profile;
    };
in
{
  packages = forAllSystems (
    system:
    let
      # Each per-skill package key is the owner-namespaced
      # `<packagePrefix><namespace>-<effectiveName>` resolved above, so
      # bare skill names like `nix-flakes` can't shadow nixpkgs entries
      # and forks can't collide. The skill's user-facing identity (install
      # path, sentinel, slash command) still uses `s.name`.
      perSkill = lib.listToAttrs (
        map (s: {
          name = s.key;
          value = s.drv;
        }) (checkedSkillSetFor system)
      );
    in
    perSkill
    // {
      default = aggregateFor system;
      ${aggName} = aggregateFor system;
    }
  );

  # Per-skill drvs indexed by bare installed name (`flakeSkillName`), the
  # stable identity — so a consumer assembling a pack with `mkSkillsEnv`
  # selects skills by bare name without reconstructing the owner-namespaced
  # package keys. Excludes the `default` / aggregate envs.
  bySkillName = forAllSystems (
    system:
    lib.listToAttrs (
      map (s: {
        inherit (s) name;
        value = s.drv;
      }) (checkedSkillSetFor system)
    )
  );

  apps = forAllSystems (
    system:
    internal.mkAppSuite {
      name = aggName;
      default = true;
      programs = {
        install = installerFor system;
        uninstall = uninstallFor system;
        preview = previewFor system;
        reap = reapFor system;
        purge = purgeFor system;
        reconcile = reconcileFor system;
      };
    }
  );

  # The declarative dev-shell one-liner: converge the target to this pack's
  # declared skill set at `--scope=project`. Only reconcile removes strays, so
  # the shell stays a pure function of the inputs. Mirrors mkAggregateSkillsFlake's
  # `reconcileScript` so consumers can drop either into a devshell startup hook
  # without reaching into `apps.reconcile.program` and appending the scope flag.
  reconcileScript = system: "${reconcileFor system}/bin/reconcile-${aggName} --scope=project";
}
