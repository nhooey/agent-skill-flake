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

      # Root-side wiring for the `skills-devshell/` sub-flake: the runtime
      # `nix run "$PRJ_ROOT/skills-devshell#<app>"` snippets spliced into the
      # dev shell below. Defaults target the `skills-devshell/` dir at project
      # scope. agent-skill-flake dogfoods its own helper here.
      devshellSkills = flakeLib.devshellSkillsHook { };
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
          apps.reap = {
            type = "app";
            program = "${reapApp}/bin/reap-agent-skill-flake";
          };

          apps.purge = {
            type = "app";
            program = "${purgeApp}/bin/purge-agent-skill-flake";
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
            name = "agent-skill-flake";
            motd = ''
              {bold}{14}🚀 Entering agent-skill-flake dev shell{reset}
              Run {bold}menu{reset} to list available commands.
            '';
            # Reconcile the dev-shell skill set at project scope on `nix
            # develop`. The set is defined in the isolated `skills-devshell/`
            # sub-flake and invoked here at RUNTIME (not a root input), so
            # agent-skill-flake keeps zero skill inputs while still dogfooding the
            # skills. `reap-skills` (below) removes the whole set in one
            # command. The skills land in `.claude/skills/` (gitignored).
            devshell.startup.install-skills.text = devshellSkills.startup;
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

              # skills
              # To purge EVERY agent-skill-flake-managed skill (any owner, strays
              # included), not just this set: nix run "$PRJ_ROOT#purge" -- --scope=project
              {
                category = "skills";
                name = "reap-skills";
                help = "Remove every skill this dev shell installed (one owner)";
                command = devshellSkills.reap;
              }
              {
                category = "skills";
                name = "update-skills-devshell";
                help = "Bump the skills-devshell/ sub-flake lock (the skill set)";
                command = ''nix flake update --flake "$PRJ_ROOT/skills-devshell" "$@"'';
              }
            ];
          };
        };
    };
}
