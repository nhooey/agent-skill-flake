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
    # a source.
    skillspkgs-combinations = {
      url = "github:nhooey/skillspkgs?dir=sources/combinations";
      inputs.nixpkgs.follows = "nixpkgs";
      # The combination's own git and nix packs come from the skill
      # repositories pinned below, so each skill is installed from one rev.
      inputs.git-skills.follows = "git-skills";
      inputs.nix-skills.follows = "nix-skills";
    };

    # Skill repositories, the same ones `github:nhooey/skillspkgs` aggregates.
    # They follow `nixpkgs` but not `agent-skill-flake`, so each keeps its own
    # compatible builder.
    coding-agent-skills = {
      url = "github:nhooey/coding-agent-skills/overnight-skills";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    git-skills = {
      url = "github:nhooey/git-skills/overnight-skills";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-skills = {
      url = "github:nhooey/nix-skills/overnight-skills";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    shell-skills = {
      url = "github:nhooey/shell-skills/overnight-skills";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    writing-skills = {
      url = "github:nhooey/writing-skills/overnight-skills";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # One `mkDevshellSkillsFlake` call: the dev shell's whole skill set,
  # surfaced as runnable apps (reconcile / purge / …). `authoring-with-git`
  # bundles the git/GitHub pack alongside the authoring tooling; the base
  # skills every agent run in this checkout needs come from their own repos.
  outputs =
    {
      nixpkgs,
      agent-skill-flake,
      skillspkgs-combinations,
      coding-agent-skills,
      shell-skills,
      writing-skills,
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
        # Safe shell commands: named deletes, PIDs, no machine-wide changes.
        { source = shell-skills; }
        # Headless runs in a checkout, a tidy scratchpad, the plans graph,
        # kanban-shaped turn responses, and how one skill refers to another.
        {
          source = coding-agent-skills;
          skills = [
            "coding-agent-headless-in-checkout"
            "coding-agent-kanban-turn-responses"
            "coding-agent-plans-as-graph"
            "coding-agent-scratchpad-scripts"
            "coding-agent-skill-references"
          ];
        }
        # Prose in READMEs, SKILL.md files, commits and replies.
        { source = writing-skills; }
      ];
    };
}
