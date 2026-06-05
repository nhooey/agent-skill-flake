{
  description = "agent-skill-flake dev-shell skill set — an isolated sub-flake invoked at RUNTIME by the root devShell, never a root input. The skill sources (agent-skills + the authoring combination) live only in THIS flake's lock, so the root agent-skill-flake stays a leaf with zero skill inputs and transitive consumers never drag the skill mesh in.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";

    # The builder lib = the PARENT working tree (`path:..`), so the combiner
    # dogfoods this repo's in-progress lib while you hack on it. A *consumer's*
    # own skills-devshell/ would instead point this at
    # `github:nhooey/agent-skill-flake` (and `follows` it from the sources below).
    agent-skill-flake.url = "path:..";

    # skillspkgs' curated `authoring-with-git` combination (nix + humanizer +
    # anthropic/daymade skill-creation + superpowers + the whole git/GitHub
    # pack), surfaced through its own subdir flake so it stays re-composable as
    # a source. This is the dev shell's entire skill set in one combination.
    skillspkgs-combinations = {
      url = "github:nhooey/skillspkgs?dir=sources/combinations";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # One `mkDevshellSkillsFlake` call: the dev shell's whole skill set as a
  # single combination, surfaced as runnable apps (reconcile / purge / …).
  # `authoring-with-git` already bundles the git/GitHub pack alongside the
  # authoring tooling, deduped into one consistent set, so it's the lone source.
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
        { source = skillspkgs-combinations.combinations.authoring-with-git; }
      ];
    };
}
