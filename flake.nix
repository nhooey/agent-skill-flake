{
  description = "flake-skills: lib.mkSkillFlake + lib.mkAllSkillsFlake for building Claude Code skill flakes";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # `self` plumbed in so lib can bake provenance (upstreamUrl, rev,
      # narHash, dirty) into each skill's sentinel without callers having to.
      flakeLib = import ./lib { inherit self; };

      # Internal helpers — used here to expose a top-level `reap` app that
      # works without any embedded skill set (pure cleanup tool).
      internal = import ./lib/internal.nix { inherit nixpkgs; };

      reapTopLevel =
        system:
        internal.mkReap system {
          appName = "flake-skills";
          inherit (flakeLib) provenance;
          profile = internal.resolveAgentProfile "claude-code";
        };
    in
    {
      lib = flakeLib;

      homeManagerModules.default = import ./home-manager-module.nix { inherit self nixpkgs; };

      darwinModules.default = import ./darwin-module.nix { inherit self nixpkgs; };

      apps = forAllSystems (system: {
        reap = {
          type = "app";
          program = "${reapTopLevel system}/bin/reap-flake-skills";
        };
      });

      checks = forAllSystems (
        system:
        import ./checks.nix { inherit self nixpkgs system; }
      );
    };
}
