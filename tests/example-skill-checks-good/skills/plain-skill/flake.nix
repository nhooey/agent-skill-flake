# A fixture skill's own flake, read by the skill-flake rule of the shared
# skill checks; never built.
{
  description = "plain-skill: a fixture of the shared skill checks";

  inputs.agent-skill-flake.url = "github:nhooey/agent-skill-flake";

  outputs =
    { nixpkgs, agent-skill-flake, ... }:
    agent-skill-flake.lib.mkSkillFlake {
      inherit nixpkgs;
      source = import ../../source.nix;
      skillName = "plain-skill";
      src = ./.;
    };
}
