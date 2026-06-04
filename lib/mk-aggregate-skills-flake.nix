# Build a whole "marketplace" flake in one call: merge an optional local
# skills directory (`skillsDir`, via mkAllSkillsFlake) with several upstream
# skill flakes (`sources`), each optionally namespace-prefixed, into one
# package set, a combined app suite over the union (install/uninstall/
# preview/reap/purge/reconcile), and a devshell-ready reconcile script.
#
# `mkAllSkillsFlake` handles a single `skillsDir`; this handles a list of
# source flakes plus an optional local dir. It mirrors mk-all-skills-flake's
# structure (`forAllSystems`, the same provenance threading) and reuses the
# marketplace helpers for the per-source plumbing.
{
  nixpkgs,
  # [ { source; skills ? null; prefix ? null; } ]
  #   source — an upstream skill flake (has .packages.<system> / .apps).
  #   skills — null takes every skill the source exposes; a list cherry-picks
  #            by *upstream* skill name (the pre-prefix identity). The choice
  #            flows into both the merged package set and the reconciled union,
  #            so a cherry-picked source contributes only those skills. An
  #            unknown name is a hard eval error listing what the source has.
  #   prefix — null merges the source's packages verbatim; otherwise every
  #            skill is re-prefixed (name, frontmatter, sentinel) via
  #            withNamePrefixSource and a fresh installer is built over it.
  sources,
  # Optional local skills dir, folded in as `base` via mkAllSkillsFlake.
  skillsDir ? null,
  # Which keys count as skills in each source, and the key prefix the merged
  # per-skill packages are exposed under. Flake-wide (one value for every
  # source); null uses the library default (`agent-skill-`), matching
  # mkAllSkillsFlake.
  packagePrefix ? null,
  # Owner namespace formula for the optional local `base` (`skillsDir`),
  # forwarded to mkAllSkillsFlake; see it for semantics. Unused when no
  # `skillsDir` is given (sources arrive already keyed by their own flakes).
  namespaceFn ? (ctx: ctx.source.owner),
  # Origin repo of the local `base`, for `namespaceFn`/`renameFn`. Same
  # shape as mkAllSkillsFlake's `source`. Only relevant with `skillsDir`.
  source ? null,
  agent ? "claude-code",
  name ? "agent-skills-all",
  # Systems to fan out over. Defaults to `defaultSystems` (the
  # `nix-systems/default` flake input injected by lib/default.nix) rather
  # than a hardcoded platform list, so downstream consumers retarget the
  # fanout by overriding the `systems` input instead of forking. Pass an
  # explicit list or `import <your systems input>` to override per call.
  systems ? defaultSystems,
  # Injected by lib/default.nix from this flake's `self`, threaded into the
  # `base = mkAllSkillsFlake {...}` build. Same role as in
  # mk-all-skills-flake.nix.
  provenance,
  # Injected by lib/default.nix from this flake's `nix-systems/default`
  # input; the default value of `systems` above, and threaded into the
  # `base` build below.
  defaultSystems,
}:
let
  inherit (nixpkgs) lib;
  marketplace = import ./marketplace.nix { };
  inherit (marketplace) withNamePrefixSource;
  # Used directly (not via marketplace) for the combined app suite, since
  # marketplace only re-exports the installer; the union needs the whole
  # install/uninstall/preview/reap/purge/reconcile family over one skill set.
  internal = import ./internal.nix { inherit nixpkgs; };
  profile = internal.resolveAgentProfile agent;

  pp = if packagePrefix == null then internal.defaultPackagePrefix else packagePrefix;

  forAllSystems = f: lib.genAttrs systems (system: f system);

  # The optional local skills dir, built exactly as a standalone
  # mkAllSkillsFlake would. Null when no `skillsDir` is given.
  base =
    if skillsDir == null then
      null
    else
      import ./mk-all-skills-flake.nix {
        inherit
          nixpkgs
          skillsDir
          systems
          name
          agent
          provenance
          defaultSystems
          namespaceFn
          source
          ;
        packagePrefix = pp;
      };

  # One source's contribution, as `[ { upstreamName; key; name; drv; } ]`
  # records — the single source of truth for both the merged package set
  # (keyed by `key`) and the combined installer (which needs the installed
  # skill `name`). The `packagePrefix` filter is applied consistently in
  # both arms, so a source's `default` / `<name>-all` aggregate keys never
  # leak into the merge (the latent bug the verbatim-merge consumer had).
  # When `prefix` is null the source's own (already-prefixed) keys are kept
  # verbatim; otherwise the wrapped skills are re-keyed under
  # `packagePrefix`. `name` is the skill's installed identity
  # (`flakeSkillName`), `key` its package attribute key, and `upstreamName`
  # its pre-prefix identity — what an entry's `skills` cherry-pick matches.
  recordsForSource =
    system:
    {
      source,
      prefix ? null,
      skills ? null,
      ...
    }:
    let
      allRecords =
        if prefix == null then
          let
            attrs = source.packages.${system};
            keys = internal.skillKeysWithPrefix attrs pp;
          in
          map (
            k:
            let
              upstreamName = attrs.${k}.passthru.flakeSkillName or (lib.removePrefix pp k);
            in
            {
              inherit upstreamName;
              key = k;
              name = upstreamName;
              drv = attrs.${k};
            }
          ) keys
        else
          let
            wrapped = withNamePrefixSource {
              inherit
                nixpkgs
                system
                source
                ;
              packagePrefix = pp;
              namePrefix = prefix;
            };
          in
          map (w: {
            # withNamePrefix joins `<prefix>-<oldName>`; strip the prefix
            # back off to recover the upstream name a cherry-pick matches.
            upstreamName = lib.removePrefix "${prefix}-" w.name;
            key = "${pp}${w.name}";
            inherit (w) name drv;
          }) wrapped;

      available = map (r: r.upstreamName) allRecords;
      unknown = lib.subtractLists available skills;
    in
    if skills == null then
      allRecords
    else if unknown != [ ] then
      throw (
        "mkAggregateSkillsFlake: source `skills` cherry-pick names not found: "
        + "${lib.concatStringsSep ", " unknown}. "
        + "Available in this source: ${lib.concatStringsSep ", " available}."
      )
    else
      builtins.filter (r: builtins.elem r.upstreamName skills) allRecords;

  upstreamRecordsFor = system: lib.concatMap (recordsForSource system) sources;

  upstreamPackagesFor =
    system:
    let
      records = upstreamRecordsFor system;
      byKey = lib.groupBy (r: r.key) records;
      dupKeys = builtins.attrNames (
        lib.filterAttrs (_: rs: lib.length (lib.unique (map (r: r.drv.outPath) rs)) > 1) byKey
      );
    in
    if dupKeys != [ ] then
      throw ''
        mkAggregateSkillsFlake '${name}': sources contribute the same package key for different skills:
          ${lib.concatStringsSep "\n  " dupKeys}
        Disambiguate with a per-source `prefix`, or drop the duplicate source.
      ''
    else
      lib.listToAttrs (
        map (r: {
          name = r.key;
          value = r.drv;
        }) records
      );

  # The base's per-skill `[ { name; drv; } ]` records, drawn from its
  # package set by the same `packagePrefix` filter that drops the
  # `default` / `<name>-all` aggregate keys. Only `name` + `drv` are
  # needed (the base package keys already merge in verbatim below).
  baseRecordsFor =
    system:
    if base == null then
      [ ]
    else
      let
        attrs = base.packages.${system};
        keys = internal.skillKeysWithPrefix attrs pp;
      in
      map (k: {
        name = attrs.${k}.passthru.flakeSkillName or (lib.removePrefix pp k);
        drv = attrs.${k};
      }) keys;

  # The whole declared set: base skills + every source's skills, as the
  # `[ { name; drv; } ]` records mkInstaller / mkReconcile consume. This
  # is the union the combined installer converges the target to. Guarded so
  # two skills can't resolve to the same install name (after per-source
  # `prefix`) and clobber each other under ~/.claude/skills/<name>.
  unionSkillsFor =
    system:
    internal.assertUniqueSkillNames {
      label = "mkAggregateSkillsFlake '${name}'";
      skills = baseRecordsFor system ++ map (r: { inherit (r) name drv; }) (upstreamRecordsFor system);
    };

  # The combined install/uninstall/preview/reap/purge/reconcile family over the
  # union, all tagged with the aggregate's `name` as their ownership
  # `appName`. reconcile is the declarative one: it converges the target
  # to exactly the union (install missing, update changed, sweep strays
  # this appName owns).
  combinedInstaller =
    system:
    internal.mkInstaller system {
      appName = name;
      skills = unionSkillsFor system;
      inherit profile;
    };
  combinedReconcile =
    system:
    internal.mkReconcile system {
      appName = name;
      skills = unionSkillsFor system;
      inherit provenance profile;
    };
  combinedPreview =
    system:
    internal.mkPreview system {
      appName = name;
      displayName = name;
      skills = unionSkillsFor system;
      inherit profile;
    };
  combinedReap =
    system:
    internal.mkReap system {
      appName = name;
      inherit provenance profile;
    };
  combinedPurge =
    system:
    internal.mkPurge system {
      appName = name;
      inherit provenance profile;
    };
  combinedUninstall =
    system:
    internal.mkUninstall system {
      appName = name;
      inherit provenance profile;
    };
in
{
  # base per-skill keys + base `default` / `<name>-all` aggregates, then
  # every source's prefixed skill keys merged on top. Sources contribute
  # only `packagePrefix`-keys, so the base aggregates survive the merge.
  packages = forAllSystems (
    system: (if base == null then { } else base.packages.${system}) // upstreamPackagesFor system
  );

  # The combined apps over the union (base + every source). `reconcile` is
  # declarative — it converges the target to the full union, so a dev shell
  # wiring `reconcileScript` removes skills a source dropped or renamed.
  # Each app is `<verb>-${name}`.
  apps = forAllSystems (system: {
    install = {
      type = "app";
      program = "${combinedInstaller system}/bin/install-${name}";
    };
    uninstall = {
      type = "app";
      program = "${combinedUninstall system}/bin/uninstall-${name}";
    };
    preview = {
      type = "app";
      program = "${combinedPreview system}/bin/preview-${name}";
    };
    reap = {
      type = "app";
      program = "${combinedReap system}/bin/reap-${name}";
    };
    purge = {
      type = "app";
      program = "${combinedPurge system}/bin/purge-${name}";
    };
    reconcile = {
      type = "app";
      program = "${combinedReconcile system}/bin/reconcile-${name}";
    };
  });

  # The declarative dev-shell one-liner: converge the target to the union
  # at `--scope=project`. Only reconcile removes strays, so the shell stays
  # a pure function of the inputs.
  reconcileScript = system: "${combinedReconcile system}/bin/reconcile-${name} --scope=project";
}
