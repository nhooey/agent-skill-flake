# Pure-data attrset of supported agent profiles.
#
# Each profile picks where a skill lands under personal scope
# (`$HOME/<personalSuffix>`) and under project scope
# (`<project-root>/<projectSuffix>`). Identical for every agent today
# but kept as two fields so a future agent that distinguishes
# user-config vs. workspace-config can do so without an API break.
#
# Add a new agent by appending an attribute here; the bash installer
# reads only the resolved profile via Nix string substitution at build
# time, so no shell-side branching is needed.
{
  claude-code = {
    personalSuffix = ".claude/skills";
    projectSuffix = ".claude/skills";
  };
  codex = {
    personalSuffix = ".codex/skills";
    projectSuffix = ".codex/skills";
  };
  cursor = {
    personalSuffix = ".cursor/skills";
    projectSuffix = ".cursor/skills";
  };
}
