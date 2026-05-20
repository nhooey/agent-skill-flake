---
name: divergent-upstream-name
description: Fixture whose frontmatter name deliberately differs from the skillName passed to mkSkillFlake, so nix flake check can prove mkSkill normalizes the installed SKILL.md frontmatter to the canonical name.
---

# divergent-upstream-name

The `name:` above is intentionally NOT `example-skill-renamed`. The build
must rewrite the frontmatter so Claude Code sees the canonical name; this
body heading is left untouched (only the first frontmatter block is
rewritten).
