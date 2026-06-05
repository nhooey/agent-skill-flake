{
  description = "flake-skills dev-shell skill set — an isolated sub-flake invoked at RUNTIME by the root devShell, never a root input. The skill sources (agent-skills + the authoring combination) live only in THIS flake's lock, so the root flake-skills stays a leaf with zero skill inputs and transitive consumers never drag the skill mesh in.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";

    # The builder lib = the PARENT working tree (`path:..`), so the combiner
    # dogfoods this repo's in-progress lib while you hack on it. A *consumer's*
    # own skills-devshell/ would instead point this at
    # `github:nhooey/flake-skills` (and `follows` it from the sources below).
    flake-skills.url = "path:..";

    # The consolidated first-party skills, cherry-picked to the git/GitHub
    # packs below. Follows the parent flake-skills so the whole sub-flake
    # resolves to one builder rev.
    agent-skills = {
      url = "github:nhooey/agent-skills";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-skills.follows = "flake-skills";
    };

    # skillspkgs' curated `authoring` combination (nix + humanizer + anthropic
    # /daymade skill-creation + superpowers), surfaced through its own subdir
    # flake so it stays re-composable as a source.
    skillspkgs-combinations = {
      url = "github:nhooey/skillspkgs?dir=sources/combinations";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # One `mkDevshellSkillsFlake` call: the dev shell's whole skill set as a
  # single combination, surfaced as runnable apps (reconcile / purge / …). The
  # git/GitHub skills are selected as the two origin packs so they don't drag
  # in (and collide with) the nix skills the `authoring` combination already
  # carries.
  outputs =
    {
      nixpkgs,
      flake-skills,
      agent-skills,
      skillspkgs-combinations,
      ...
    }@inputs:
    flake-skills.lib.mkDevshellSkillsFlake {
      inherit nixpkgs;
      systems = import inputs.systems;
      name = "flake-skills-devshell";
      envName = "agent-skills-flake-skills-devshell";
      packagePrefix = "agent-skill-";
      sources = [
        {
          source = agent-skills;
          pack = "agent-skills-git-all";
        }
        {
          source = agent-skills;
          pack = "agent-skills-github-all";
        }
        { source = skillspkgs-combinations.combinations.authoring; }
      ];
    };
}
