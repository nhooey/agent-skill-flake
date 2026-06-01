{
  description = "flake-skills authoring skills: third-party Claude Code skills installed into the flake-skills dev shell for authoring this repo — deliberately kept separate from the skills this repo outputs.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    systems.url = "github:nix-systems/default";

    # `flake-skills` is the builder library, not a skill — it provides
    # `mkAggregateSkillsFlake`. Followed by the parent flake so both share
    # one evaluation.
    flake-skills = {
      url = "github:nhooey/flake-skills";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Every input below this divider is a skill source.
    skills-nix = {
      url = "github:nhooey/skills-nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-skills.follows = "flake-skills";
      };
    };
    humanizer = {
      url = "github:nhooey/skillspkgs?dir=pkgs/humanizer";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-skills.follows = "flake-skills";
      };
    };
    skill-creator = {
      url = "github:nhooey/skillspkgs?dir=pkgs/skill-creator";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-skills.follows = "flake-skills";
      };
    };
    superpowers = {
      url = "github:nhooey/skillspkgs?dir=pkgs/superpowers";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-skills.follows = "flake-skills";
      };
    };
  };

  outputs =
    {
      nixpkgs,
      flake-parts,
      systems,
      flake-skills,
      skills-nix,
      humanizer,
      skill-creator,
      superpowers,
      ...
    }@inputs:
    let
      # No `skillsDir`: this flake outputs no skills of its own, it only
      # aggregates external sources so the parent flake can install them.
      # A source with no `skills` installs all of it; `skills = [ ... ]`
      # cherry-picks; `prefix` namespaces the pack to avoid name clashes.
      agg = flake-skills.lib.mkAggregateSkillsFlake {
        inherit nixpkgs;
        # Distinct ownership name so the declarative `reconcile` sweep is
        # scoped to *these* authoring skills. The parent flake-skills flake
        # installs its own base skills into the same project-scope dir under
        # the default `agent-skills-all` appName; a different name here keeps
        # each reconcile owning only its own slice (an entry the lock
        # attributes to another appName is left alone).
        name = "flake-skills-authoring";
        packagePrefix = "agent-skill-";
        sources = [
          {
            source = skills-nix;
            skills = [
              "nix-flakes"
              "nix-garnix-ci"
            ];
          }
          { source = humanizer; }
          {
            source = skill-creator;
            prefix = "anthropic";
          }
          {
            source = superpowers;
            prefix = "superpowers";
          }
        ];
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      # `reconcileScript` (`system -> string`, a one-liner that converges the
      # project-scope skills dir to exactly this union) is consumed by the
      # parent flake's dev shell startup. It is not a per-system output, so it
      # lives under `flake` rather than `perSystem`.
      flake.reconcileScript = agg.reconcileScript;

      # `packages` / `apps` are surfaced per-system for `nix eval` / `nix run`
      # inspection of the cherry-picked set.
      perSystem =
        { system, ... }:
        {
          packages = agg.packages.${system};
          apps = agg.apps.${system};
        };
    };
}
