{
  description = "flake-skills: lib.mkSkillFlake + lib.mkAllSkillsFlake for building Claude Code skill flakes";

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

    # The dev-shell skill set, as its own sub-flake so its skill-source inputs
    # (skills-git, skillspkgs' authoring combination) stay isolated in
    # `skills-devshell/flake.lock` rather than in this library's inputs. The
    # combination is formed there; the dev shell consumes its `reconcileScript`.
    #
    # Referenced via `github:…?dir=` rather than `path:./skills-devshell`: being
    # the library, this flake has no `flake-skills` input to point the sub-flake
    # at via `follows`, so a relative `path:` here would leave the sub-flake's
    # own `flake-skills` (which itself carries this `skills-devshell` input) to
    # re-resolve a nested relative path from the wrong base and fail with a
    # doubled `skills-devshell/skills-devshell/…` path. A `github:?dir` ref is
    # fetched standalone, sidestepping that — at the cost of the dev shell using
    # the last-pushed skill set rather than local edits (the set rarely changes).
    # Consumers that DO have a `flake-skills` input should instead use
    # `path:./skills-devshell` + `inputs.flake-skills.follows` (see README).
    skills-devshell = {
      url = "github:nhooey/flake-skills?dir=skills-devshell";
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
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      imports = [
        inputs.devshell.flakeModule
        inputs.treefmt-nix.flakeModule
      ];

      # System-independent outputs: the library and the activation modules.
      flake = {
        lib = flakeLib;
        homeManagerModules.default = import ./home-manager-module.nix { inherit self nixpkgs; };
        darwinModules.default = import ./darwin-module.nix { inherit self nixpkgs; };
      };

      perSystem =
        { pkgs, system, ... }:
        let
          reapApp = internal.mkReap system {
            appName = "flake-skills";
            inherit (flakeLib) provenance;
            profile = internal.resolveAgentProfile "claude-code";
          };

          # Lineage-wide teardown, exposed here (like reap) so it runs
          # transiently with no embedded skill set:
          #   nix run github:nhooey/flake-skills#purge -- --scope=personal
          # clears every flake-skills-managed skill from a scope even after
          # the hooks that installed them are gone.
          purgeApp = internal.mkPurge system {
            appName = "flake-skills";
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
          apps.reap = {
            type = "app";
            program = "${reapApp}/bin/reap-flake-skills";
          };

          apps.purge = {
            type = "app";
            program = "${purgeApp}/bin/purge-flake-skills";
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

          devshells.default = {
            name = "flake-skills";
            motd = ''
              {bold}{14}🚀 Entering flake-skills dev shell{reset}
              Run {bold}menu{reset} to list available commands.
            '';
            # Install the dev-shell skill set (git/GitHub + the authoring
            # combination) at project scope on `nix develop`. The skills-devshell
            # sub-flake outputs the reconcile one-liner as text per system; this
            # just splices it in — the root knows nothing about how it's built.
            devshell.startup.install-skills.text = ''
              ${inputs.skills-devshell.reconcileScript.${system}}
            '';
            packages = [
              batsWith
              pkgs.coreutils
              pkgs.findutils
              pkgs.git
              pkgs.jq
            ];
            commands = [
              # ci
              {
                category = "ci";
                name = "check";
                help = "Run the full test suite via nix flake check";
                command = ''nix flake check "$@"'';
              }

              # dev
              {
                category = "dev";
                name = "fmt";
                help = "Format the tree with treefmt (nixfmt + shfmt)";
                command = ''nix fmt "$@"'';
              }

              # maintenance
              {
                category = "maintenance";
                name = "update-flake";
                help = "Update all flake inputs and rewrite flake.lock";
                command = ''nix flake update "$@"'';
              }
            ];
          };
        };
    };
}
