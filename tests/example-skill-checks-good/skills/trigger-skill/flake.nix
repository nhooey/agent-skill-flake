# A fixture skill's own flake, read by the skill-flake rule of the shared
# skill checks; never built. Its `outputs` takes its inputs whole.
{
  description = "trigger-skill: a fixture of the shared skill checks";

  outputs =
    inputs:
    inputs.agent-skill-flake.lib.mkSkillFlake {
      inherit (inputs) nixpkgs;
      skillName = "trigger-skill";
      src = ./.;
    };
}
