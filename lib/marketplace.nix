# Marketplace / aggregation helpers — the supported public surface for
# building a flake that pulls several upstream skill flakes, optionally
# prefixes them, and installs an arbitrary skill set. These promote logic
# that aggregator ("marketplace") consumers used to hand-roll against the
# private `internal.nix` module.
#
# Kept in their own module (rather than inline in lib/default.nix) so both
# the public surface (lib/default.nix) and lib/mk-aggregate-skills-flake.nix
# can use them without importing through default.nix (which would be a
# circular import, since default.nix takes `self`).
#
# Signature convention: every single-system helper here takes
# `{ nixpkgs, system, ... }` and derives `pkgs =
# nixpkgs.legacyPackages.${system}` internally — matching every builder in
# internal.nix / mk-all-skills-flake.nix. `internal.nix` is imported lazily
# with the `nixpkgs` each call is handed, so this module has no top-level
# nixpkgs dependency.
{ }:
let
  withNamePrefix = import ./with-name-prefix.nix { };

  # Installer over an arbitrary, already-built skill set. The single
  # primitive that used to force consumers to import internal.nix: a public
  # wrapper around `internal.mkInstaller` that resolves the agent profile
  # itself.
  mkInstaller =
    {
      nixpkgs,
      system,
      appName,
      # [ { name; drv; } ] — already-built skills (e.g. from
      # withNamePrefixSource, or a source's own package set).
      skills,
      agent ? "claude-code",
    }:
    let
      internal = import ./internal.nix { inherit nixpkgs; };
    in
    internal.mkInstaller system {
      inherit appName skills;
      profile = internal.resolveAgentProfile agent;
    };

  # The plural of `withNamePrefix`: prefix-wrap every skill package a source
  # flake exposes, returning `[ { name; drv; } ]` records keyed by the
  # prefixed skill name. Filtering by `packagePrefix` also drops the
  # source's `default` / `<name>-all` aggregate keys, which downstream
  # helpers (and the aggregate package merge) rely on.
  withNamePrefixSource =
    {
      nixpkgs,
      system,
      namePrefix,
      # An upstream skill flake (has `.packages.<system>`).
      source,
      # Which keys in `source.packages.<system>` count as skills. Defaults
      # to the library's own mkAllSkillsFlake/mkSkillFlake default.
      packagePrefix ? "skill-",
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      attrs = source.packages.${system};
      keys = builtins.filter (nixpkgs.lib.hasPrefix packagePrefix) (builtins.attrNames attrs);
    in
    map (
      k:
      let
        wrapped = withNamePrefix {
          inherit pkgs namePrefix;
          skill = attrs.${k};
        };
      in
      {
        name = wrapped.passthru.flakeSkillName;
        drv = wrapped;
      }
    ) keys;

  # Composite of withNamePrefixSource + mkInstaller: prefix-wrap a source,
  # then build a fresh installer over the wrapped set (the source's own
  # installer was sealed against un-prefixed names at build time).
  mkPrefixedInstaller =
    {
      nixpkgs,
      system,
      source,
      namePrefix,
      packagePrefix ? "skill-",
      agent ? "claude-code",
      appName ? "agent-skills-${namePrefix}-all",
    }:
    mkInstaller {
      inherit nixpkgs system appName agent;
      skills = withNamePrefixSource {
        inherit
          nixpkgs
          system
          namePrefix
          source
          packagePrefix
          ;
      };
    };

  # The `"<installer-bin> <args>"` install string for one source — prefix
  # or not, all skills or a subset. Independent of any devshell so a
  # consumer can assemble its own startup script / Makefile / app.
  installCommandFor =
    {
      nixpkgs,
      system,
      source,
      # null → use the source's own install app verbatim. Otherwise build a
      # fresh prefixed installer over the wrapped source.
      prefix ? null,
      # null → install everything the installer exposes. Otherwise the
      # named subset.
      skills ? null,
      packagePrefix ? "skill-",
      agent ? "claude-code",
      scope ? "project",
    }:
    let
      lib = nixpkgs.lib;
      appName = "agent-skills-${prefix}-all";
      bin =
        if prefix == null then
          source.apps.${system}.install.program
        else
          "${mkPrefixedInstaller {
            inherit
              nixpkgs
              system
              source
              agent
              packagePrefix
              appName
              ;
            namePrefix = prefix;
          }}/bin/install-${appName}";
      args =
        if skills == null then
          "--scope=${scope}"
        else
          "--scope=${scope} ${lib.concatStringsSep " " skills}";
    in
    "${bin} ${args}";

  # Resolve an agent profile by name (public wrapper around the internal
  # resolver) for callers who need the profile directly.
  resolveAgentProfile =
    { nixpkgs, agent }:
    (import ./internal.nix { inherit nixpkgs; }).resolveAgentProfile agent;

  # Pure-data attrset of supported agent profiles (no nixpkgs needed).
  agentProfiles = import ./agent-profiles.nix;
in
{
  inherit
    mkInstaller
    withNamePrefixSource
    mkPrefixedInstaller
    installCommandFor
    resolveAgentProfile
    agentProfiles
    ;
}
