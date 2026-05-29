# Build a whole "marketplace" flake in one call: merge an optional local
# skills directory (`skillsDir`, via mkAllSkillsFlake) with several upstream
# skill flakes (`sources`), each optionally namespace-prefixed, into one
# package set + apps + a devshell-ready install script.
#
# `mkAllSkillsFlake` handles a single `skillsDir`; this handles a list of
# source flakes plus an optional local dir. It mirrors mk-all-skills-flake's
# structure (`forAllSystems`, the same provenance threading) and reuses the
# marketplace helpers for the per-source plumbing.
{
  nixpkgs,
  # [ { source; skills ? null; prefix ? null; } ]
  #   source — an upstream skill flake (has .packages.<system> / .apps).
  #   skills — null installs everything; a list cherry-picks (devshell
  #            install line only; the merged package set is unaffected).
  #   prefix — null merges the source's packages verbatim; otherwise every
  #            skill is re-prefixed (name, frontmatter, sentinel) via
  #            withNamePrefixSource and a fresh installer is built over it.
  sources,
  # Optional local skills dir, folded in as `base` via mkAllSkillsFlake.
  skillsDir ? null,
  # Which keys count as skills in each source, and the key prefix the merged
  # per-skill packages are exposed under. Flake-wide (one value for every
  # source); matches mkAllSkillsFlake's own default.
  packagePrefix ? "skill-",
  agent ? "claude-code",
  name ? "agent-skills-all",
  systems ? [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ],
  # Injected by lib/default.nix from this flake's `self`, threaded into the
  # `base = mkAllSkillsFlake {...}` build. Same role as in
  # mk-all-skills-flake.nix.
  provenance,
}:
let
  inherit (nixpkgs) lib;
  marketplace = import ./marketplace.nix { };
  inherit (marketplace) withNamePrefixSource installCommandFor;

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
          packagePrefix
          agent
          provenance
          ;
      };

  # One source's contribution to the merged per-system package set. The
  # `packagePrefix` filter is applied consistently in both arms, so a
  # source's `default` / `<name>-all` aggregate keys never leak into the
  # merge (the latent bug the verbatim-merge consumer had). When `prefix`
  # is null the source's own (already-prefixed) keys are kept verbatim;
  # otherwise the wrapped skills are re-keyed under `packagePrefix`.
  packagesForSource =
    system:
    {
      source,
      prefix ? null,
      ...
    }:
    if prefix == null then
      let
        attrs = source.packages.${system};
        keys = builtins.filter (lib.hasPrefix packagePrefix) (builtins.attrNames attrs);
      in
      lib.listToAttrs (
        map (k: {
          name = k;
          value = attrs.${k};
        }) keys
      )
    else
      let
        wrapped = withNamePrefixSource {
          inherit
            nixpkgs
            system
            packagePrefix
            source
            ;
          namePrefix = prefix;
        };
      in
      lib.listToAttrs (
        map (w: {
          name = "${packagePrefix}${w.name}";
          value = w.drv;
        }) wrapped
      );

  upstreamPackagesFor =
    system: lib.foldl' (acc: entry: acc // packagesForSource system entry) { } sources;
in
{
  # base per-skill keys + base `default` / `<name>-all` aggregates, then
  # every source's prefixed skill keys merged on top. Sources contribute
  # only `packagePrefix`-keys, so the base aggregates survive the merge.
  packages = forAllSystems (
    system: (if base == null then { } else base.packages.${system}) // upstreamPackagesFor system
  );

  # Base apps (install/uninstall/preview/reap/reconcile over the local
  # skills dir). `apps.install` covers base alone; sources are installed via
  # `installScript` in the devshell. Empty when there is no local dir.
  apps = forAllSystems (system: if base == null then { } else base.apps.${system});

  # Newline-joined install commands for a devshell startup hook: the local
  # base (if any) first, then one line per source. Each installs at the
  # given scope (default `project`).
  installScript =
    system:
    let
      baseLine = lib.optional (base != null) (installCommandFor {
        inherit nixpkgs system agent;
        source = base;
      });
      sourceLines = map (
        entry: installCommandFor ({ inherit nixpkgs system packagePrefix agent; } // entry)
      ) sources;
    in
    lib.concatStringsSep "\n" (baseLine ++ sourceLines);
}
