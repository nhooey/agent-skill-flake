{
  description = "flake-skills dev-shell skills: the skill set installed into the flake-skills dev shell for working on this repo (git/GitHub hygiene plus skillspkgs' authoring combination) — deliberately kept separate from the skills this repo outputs.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    systems.url = "github:nix-systems/default";

    # `flake-skills` is the builder library, not a skill — it provides
    # `mkCombination`. Followed by every skill source below so the whole tree
    # shares one evaluation.
    flake-skills = {
      url = "github:nhooey/flake-skills";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Every input below this divider is a skill source.
    skills-git = {
      url = "github:nhooey/skills-git";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-skills.follows = "flake-skills";
      };
    };

    # skillspkgs' curated `authoring` combination (nix-*, humanizer,
    # skill-creator, superpowers). Pulled as a single source rather than
    # re-listing its four component sources here — mkCombination makes a
    # combination re-composable, so this references upstream curation instead
    # of duplicating it.
    skillspkgs-combinations = {
      url = "github:nhooey/skillspkgs?dir=sources/combinations";
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
      skills-git,
      skillspkgs-combinations,
      ...
    }@inputs:
    let
      forSystems = nixpkgs.lib.genAttrs (import systems);

      # No `skillsDir`: this flake outputs no skills of its own, it only
      # combines external sources into the dev-shell skill set the parent
      # installs in one reconcile — the git/GitHub pack (not authoring at all)
      # plus skillspkgs' `authoring` combination spliced in as a source. It's a
      # combination (not a plain aggregate) so it carries a home-manager `env`
      # too, though the dev shell only consumes `reconcileScript`.
      devshellSkills = flake-skills.lib.mkCombination {
        inherit nixpkgs;
        # `name` is the reconcile ownership appName — the parent flake ships no
        # skills of its own, so this combination is the sole owner of the dev
        # shell's project scope.
        name = "flake-skills-devshell";
        envName = "agent-skills-flake-skills-devshell";
        packagePrefix = "agent-skill-";
        sources = [
          { source = skills-git; }
          { source = skillspkgs-combinations.combinations.authoring; }
        ];
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      # The reconcile one-liner as ready-to-run TEXT, keyed by system — NOT a
      # `system -> string` function. A consumer's dev shell splices
      # `reconcileScript.${system}` straight into a startup hook, so it never
      # has to know this is a flake-skills reconcile (it just runs the text).
      flake.reconcileScript = forSystems (system: devshellSkills.reconcileScript system);

      # `packages` / `apps` are surfaced per-system for `nix eval` / `nix run`
      # inspection of the combined set.
      perSystem =
        { system, ... }:
        {
          packages = devshellSkills.packages.${system};
          apps = devshellSkills.apps.${system};
        };
    };
}
