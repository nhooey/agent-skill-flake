# Pure-data attrset of supported agent profiles.
#
# Each profile picks where a skill lands under personal scope
# (`$HOME/<personalSuffix>`) and under project scope
# (`<project-root>/<projectSuffix>`). Kept as two fields because an agent
# can read its user config and its workspace config from different places.
#
# `projectLink` (optional) is a project-root-relative path that install and
# reconcile point at `projectSuffix` with a relative symlink at project
# scope. Claude Code reads project skills from `.claude/skills/`, so its
# profile installs into the shared `.agents/skills/` and links
# `.claude/skills -> ../.agents/skills`.
#
# Add a new agent by appending an attribute here; the bash installer
# reads only the resolved profile via Nix string substitution at build
# time, so no shell-side branching is needed.
{
  claude-code = {
    personalSuffix = ".claude/skills";
    projectSuffix = ".agents/skills";
    projectLink = ".claude/skills";
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
