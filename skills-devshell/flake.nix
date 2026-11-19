{
  description = "agent-skill-flake dev-shell skill set — an isolated sub-flake invoked at RUNTIME by the root devShell, never a root input. The skill source (skillspkgs' skill-packaging combination) lives only in THIS flake's lock, so the root agent-skill-flake stays a leaf with zero skill inputs and transitive consumers never drag the skill mesh in.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";

    # The builder lib = the PARENT working tree (`path:..`), so the combiner
    # dogfoods this repo's in-progress lib while you hack on it. A *consumer's*
    # own skills-devshell/ would instead point this at
    # `github:nhooey/agent-skill-flake`.
    agent-skill-flake.url = "path:..";

    # skillspkgs' per-family combinations, surfaced through their own subdir
    # flake so each stays re-composable as a source.
    skillspkgs-combinations = {
      url = "github:nhooey/skillspkgs?dir=sources/combinations";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # One `mkDevshellSkillsFlake` call: the dev shell's whole skill set,
  # surfaced as runnable apps (reconcile / purge / …). This repository is in
  # the skill-packaging family, and its combination is the whole set: the
  # family shares every language and tool used here (Nix, shell, bats).
  outputs =
    {
      nixpkgs,
      agent-skill-flake,
      skillspkgs-combinations,
      ...
    }@inputs:
    agent-skill-flake.lib.mkDevshellSkillsFlake {
      inherit nixpkgs;
      systems = import inputs.systems;
      # envName is omitted: the default `agent-skills-${name}` already yields
      # `agent-skills-agent-skill-flake-devshell`, dogfooding the lib default.
      name = "agent-skill-flake-devshell";
      packagePrefix = "agent-skill-";
      sources = [
        { source = skillspkgs-combinations.combinations.skill-packaging; }
      ];
    };
}
