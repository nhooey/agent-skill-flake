{
  description = "agent-skill-flake: lib.mkSkillFlake + lib.mkAllSkillsFlake for building Claude Code skill flakes";

  inputs = {
    # Pinned to the rolling `nixos-unstable` branch for recent toolchains;
    # the rev lives in flake.lock. Moving to a stable `nixos-XX.YY` branch
    # would be a deliberate project decision, not a routine `nix flake update`.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    systems.url = "github:nix-systems/default";

    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-parts,
      systems,
      ...
    }@inputs:
    let
      # `self` plumbed in so lib can bake provenance (upstreamUrl, rev,
      # narHash, dirty) into each skill's sentinel without callers having to.
      flakeLib = import ./lib { inherit self; };

      # Internal helpers — used here to expose a top-level `reap` app that
      # works without any embedded skill set (pure cleanup tool).
      internal = import ./lib/internal.nix { inherit nixpkgs; };

      # The two flake-parts pieces that make up the devshell-skills bundle:
      # agent-skill-flake's OWN devshell flakeModule + the local module. Defined
      # ONCE here and referenced in BOTH the exported bundle (flake.flakeModules.
      # devshellSkills) and the dogfood `imports` below, so the two sites can
      # never drift apart silently.
      devshellSkillsModule = [
        inputs.devshell.flakeModule
        ./lib/devshell-skills-flake-module.nix
      ];
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      # Dogfood the exposed dev-shell module: it provides the motd, the
      # install-skills startup, and the standard + skills command lists, so
      # the hand-rolled wiring below collapses to the options block plus this
      # repo's own `packages`. We spread `devshellSkillsModule` (the same two
      # pieces the exported bundle wraps) DIRECTLY here rather than importing
      # `self.flakeModules.devshellSkills`: referencing `self`'s outputs from
      # inside the flake's own `imports` is an infinite recursion (the import
      # graph is needed to compute `self`). Consumers, importing this flake as
      # an input, have no such cycle and use the single bundled module. Both
      # this dogfood and the exported bundle reference the one
      # `devshellSkillsModule` binding (see the `let` above), so they can't
      # drift apart.
      imports = [
        inputs.treefmt-nix.flakeModule
      ]
      ++ devshellSkillsModule;

      # Dev-shell options consumed by self.flakeModules.devshellSkills above.
      # Defaults already target `skills-devshell/` at project scope with
      # reconcile/purge, so only `name` differs from the stock defaults.
      agent-skill-flake.devshellSkills.name = "agent-skill-flake";

      # System-independent outputs: the library, the activation modules, and
      # the flake-parts dev-shell module consumers import in place of the
      # hand-rolled devshell wiring (see lib/devshell-skills-flake-module.nix
      # for the why — ~10 repos duplicate this boilerplate).
      flake = {
        lib = flakeLib;
        homeManagerModules.default = import ./home-manager-module.nix { inherit self nixpkgs; };
        darwinModules.default = import ./darwin-module.nix { inherit self nixpkgs; };

        # The exposed module bundles agent-skill-flake's OWN devshell
        # flakeModule, so a consumer needs no `devshell` input of their own —
        # importing this one module is enough, and the devshell version is
        # pinned to agent-skill-flake's lock. (This repo can't import this
        # bundle to dogfood — see the `imports` comment above on the
        # self-reference cycle — so it spreads the same `devshellSkillsModule`
        # binding directly. Both sites share that one binding so they can't
        # drift.)
        flakeModules.devshellSkills = {
          imports = devshellSkillsModule;
        };
        flakeModules.default = self.flakeModules.devshellSkills;
      };

      perSystem =
        { pkgs, system, ... }:
        let
          reapApp = internal.mkReap system {
            appName = "agent-skill-flake";
            inherit (flakeLib) provenance;
            profile = internal.resolveAgentProfile "claude-code";
          };

          # Lineage-wide teardown, exposed here (like reap) so it runs
          # transiently with no embedded skill set:
          #   nix run github:nhooey/agent-skill-flake#purge -- --scope=personal
          # clears every agent-skill-flake-managed skill from a scope even after
          # the hooks that installed them are gone.
          purgeApp = internal.mkPurge system {
            appName = "agent-skill-flake";
            inherit (flakeLib) provenance;
            profile = internal.resolveAgentProfile "claude-code";
          };

          # bats + the assertion/file/support helper libraries — the same set
          # checks.nix builds, so contributors can run the suite by hand.
          batsWith = pkgs.bats.withLibraries (p: [
            p.bats-support
            p.bats-assert
            p.bats-file
          ]);
        in
        {
          # Route the two root-level cleanup apps through the same
          # `mkAppSuite` the lib's builders use, so they carry the shared
          # per-verb `meta.description` instead of reporting "no description"
          # in `nix flake show`.
          apps = internal.mkAppSuite {
            name = "agent-skill-flake";
            programs = {
              reap = reapApp;
              purge = purgeApp;
            };
          };

          checks = import ./checks.nix { inherit self nixpkgs system; };

          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
            programs.shfmt.enable = true;
            settings.global.excludes = [
              ".claude/**" # vendored third-party skills — not ours to reformat
              "*.bats" # bats `@test` syntax isn't valid sh; shfmt would choke
            ];
          };

          # The motd, install-skills startup, and standard + skills command
          # lists now come from self.flakeModules.devshellSkills (imported
          # above). Only this repo's own tool `packages` remain hand-rolled —
          # devshell `packages` is a list option, so these concatenate onto
          # whatever the module contributes (currently none). The reconcile at
          # project scope, the `reap-skills`/`update-skills-devshell` pair, and
          # the purge-everything escape hatch all live in the module/hook now.
          devshells.default.packages = [
            batsWith
            pkgs.coreutils
            pkgs.findutils
            pkgs.git
            pkgs.jq
          ];
        };
    };
}
