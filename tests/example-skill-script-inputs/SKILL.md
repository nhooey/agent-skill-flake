---
name: example-skill-script-inputs
description: Test fixture for agent-skill-flake. Builds via lib.mkSkillFlake with scriptInputs during nix flake check; not intended to be installed.
---

# example-skill-script-inputs

A SKILL.md whose `scripts/greet.sh` runs `hello`, a tool the build puts
on the script's PATH through `scriptInputs`.
