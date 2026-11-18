# A fixture skill's own flake, read by the skill-flake rule of the shared
# skill checks; never built. It names another skill.
{
  outputs =
    { nixpkgs, agent-skill-flake, ... }:
    agent-skill-flake.lib.mkSkillFlake {
      inherit nixpkgs;
      skillName = "another-name";
      src = ./.;
    };
}
