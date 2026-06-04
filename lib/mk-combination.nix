# A "combination": a curated cross-cutting union of skills, returned in
# the canonical source-able shape. A thin wrapper over
# mkAggregateSkillsFlake — the aggregate is already source-able (it returns
# `packages`), so the only thing a combination adds is one home-manager
# `env` per system. So a combination is, by construction, both directly
# consumable (packages/apps/reconcile) and re-composable as a source
# (`{ source = it; }`), with no hand-wrapper to drop `packages` on the floor.
#
# A dedicated helper rather than enriching mkAggregateSkillsFlake: not every
# aggregate wants an env (it's a home-manager activation carrier, a separate
# consumption path), and folding it in would force an `envName` the aggregate
# has no natural value for.
{
  nixpkgs,
  # Identical to mkAggregateSkillsFlake.sources.
  sources,
  # Reconcile-ownership appName, e.g. "skillspkgs-authoring".
  name,
  # Home-manager env package name. Can't be derived from the aggregate
  # (it carries no `name`), so defaults to `name`.
  envName ? name,
  # null uses the library default (`agent-skill-`), matching the aggregate.
  packagePrefix ? null,
  agent ? "claude-code",
  systems ? defaultSystems,
  # Injected by lib/default.nix, as in the other builders.
  provenance,
  defaultSystems,
}:
let
  internal = import ./internal.nix { inherit nixpkgs; };
  mkSkillsEnv = import ./mk-skills-env.nix { };

  pp = if packagePrefix == null then internal.defaultPackagePrefix else packagePrefix;

  forAllSystems = internal.forAllSystems systems;

  # The whole install/reconcile surface AND the source-able package set;
  # a combination *is* this plus an env, so reuse it verbatim.
  agg = import ./mk-aggregate-skills-flake.nix {
    inherit
      nixpkgs
      sources
      name
      agent
      systems
      provenance
      defaultSystems
      ;
    packagePrefix = pp;
  };

  # One env per system over the aggregate's prefixed skill drvs. Same
  # `skillKeysWithPrefix` sift the aggregate uses internally — lifted here
  # so callers stop hand-rolling it (and stop dropping `packages`). Drvs are
  # reused, not rebuilt; each already carries the `flakeSkillName` mkSkillsEnv
  # needs.
  envFor =
    system:
    let
      attrs = agg.packages.${system};
    in
    mkSkillsEnv {
      pkgs = nixpkgs.legacyPackages.${system};
      name = envName;
      skills = map (k: attrs.${k}) (internal.skillKeysWithPrefix attrs pp);
    };
in
{
  inherit (agg) packages apps reconcileScript;
  env = forAllSystems envFor;
}
