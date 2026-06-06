# Per-repo dev-shell skill set, scaffolded by `nix run <upstream>#init`.
#
# WHY this sub-flake exists separately from your root flake.nix: flake
# `inputs` must be static literals the evaluator reads BEFORE `outputs`
# runs, so the skill-source inputs below cannot be factored into a library
# the way the rest of the wiring is. Keeping them in their OWN sub-flake
# (with its OWN lock) means your root flake's input graph stays a clean
# leaf — transitive consumers of your repo never drag the skill mesh in.
# The root devShell invokes the apps below at RUNTIME by path, never as an
# input (see the root `flake.nix` wiring printed by `init`).
#
# TODO, two steps to finish wiring this up:
#   1. Fill in `sources` below with the skill flakes you want in this dev
#      shell. Each entry is `{ source = <flake>; }` (optionally with
#      `skills`, `pack`, or `prefix` — see mkDevshellSkillsFlake docs).
#   2. Run `nix flake lock ./skills-devshell` to pin the inputs you add.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";

    agent-skill-flake = {
      url = "@UPSTREAM_URL@";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, agent-skill-flake, ... }@inputs:
    agent-skill-flake.lib.mkDevshellSkillsFlake {
      inherit nixpkgs;
      systems = import inputs.systems;
      name = "@NAME@-devshell";
      sources = [
        # TODO: list your skill sources here, e.g.:
        #   { source = inputs.some-skills-flake; }
      ];
    };
}
