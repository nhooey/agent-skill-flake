# Build the outputs of a per-repo `skills-devshell/` sub-flake: one
# `mkCombination` (the dev shell's entire skill set, owned by a single
# reconcile appName) surfaced as runnable apps plus a re-composable source.
#
# The pattern: a repo drops a `skills-devshell/` sub-flake whose `outputs` is
# just a call to this, listing the skill sources it wants in its dev shell. The
# repo's ROOT devShell then invokes the apps at RUNTIME
# (`nix run "$PRJ_ROOT/skills-devshell#reconcile" -- --scope=project`) — see
# `devshell-skills-hook.nix` for that wiring. Because the sub-flake is invoked
# at runtime and never declared as a root input, the skill sources live only in
# THIS sub-flake's lock: the root keeps a clean input graph (a true leaf with
# zero skill inputs) and transitive consumers of the root never drag the skill
# mesh in. One combination means one `purge` (or `reap`) removes the whole set
# in a single command.
{
  nixpkgs,
  # Same `sources` contract as mkCombination / mkAggregateSkillsFlake:
  # `[ { source; skills ? null; pack ? null; prefix ? null; } ]`.
  sources,
  # Reconcile-ownership appName — the single owner, so one `purge` (or `reap`)
  # sweeps the whole set. Also the `<verb>-<name>` suffix on each app's binary.
  name ? "devshell-skills",
  # Home-manager env package name. Defaults to `agent-skills-${name}` —
  # the shared `agent-skills-` namespace prefix mkAllSkillsFlake uses for its
  # `agent-skills-<owner>-all` key — so consumers (whose `name` is already
  # `<repo>-devshell`) can omit it and get `agent-skills-<repo>-devshell`.
  # This deliberately diverges from the bare `envName ? name` of the wrapped
  # `mkCombination`: a raw combination has no repo-namespace convention to
  # lean on, whereas a per-repo dev-shell set always does. The wrapper passes
  # this through explicitly below, so the two defaults never both fire.
  envName ? "agent-skills-${name}",
  # null uses the library default (`agent-skill-`).
  packagePrefix ? null,
  agent ? "claude-code",
  systems ? defaultSystems,
  # Injected by lib/default.nix, as in the other builders.
  provenance,
  defaultSystems,
}:
let
  internal = import ./internal.nix { inherit nixpkgs; };
  forAllSystems = internal.forAllSystems systems;

  combo = import ./mk-combination.nix {
    inherit
      nixpkgs
      systems
      provenance
      defaultSystems
      sources
      name
      envName
      packagePrefix
      agent
      ;
  };
in
{
  # Runnable apps in flake-app shape: install / uninstall / preview / reap /
  # purge / reconcile. `nix run .#reconcile -- --scope=project` converges the
  # set; `nix run .#purge -- --scope=project` removes everything it owns.
  apps = forAllSystems (system: combo.apps.${system});

  # Expose the combination's package set so the sub-flake is itself a valid
  # `{ source = …; }` for further composition, and so `nix flake show` lists
  # the union's per-skill packages.
  packages = forAllSystems (system: combo.packages.${system});

  # The combination itself (re-composable source + home-manager `env`).
  combinations.default = combo;
}
