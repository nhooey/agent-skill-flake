# A fixture skill's own flake, read by the skill-flake rule of the shared
# skill checks; never built.
{
  outputs =
    { agent-skill-flake, ... }:
    agent-skill-flake.lib.mkSkillFlake {
      skillName = "crlf-skill";
      src = ./.;
    };
}
