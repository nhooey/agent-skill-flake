# agent-skill-flake

A Nix flake library that builds installable flakes from agent-skill
directories (`lib.mkSkillFlake`, `lib.mkAllSkillsFlake`, the aggregate and
dev-shell builders), plus the `agent-skill-flake` command and the
`reap`, `check`, `purge` and `init` apps. The builders live in `lib/`, the
shell they run in `lib/bash/`, and the Home Manager and nix-darwin modules
at the root. The root flake has no skill inputs; the skills an agent uses
while working here come from the `skills-devshell/` sub-flake, which the
dev shell installs into `.agents/skills/` on entry.

## Build and test

`nix develop` enters the dev shell, with bats, jq and git, and installs the
project's skills. Its `menu` lists every command; the ones for working here:

- `check` builds every check in `checks.nix`: the bats suites under
  `tests/`, the fixture skill flakes built from `tests/example-*`, and the
  Home Manager and nix-darwin module tests.
- `flake-checks list` names the checks, and `flake-checks run <name>...`
  builds only those, with their logs.
- `fmt` formats Nix and shell files with treefmt.
- `update-flake` bumps the root flake's inputs; `update-skills-devshell`
  bumps the `skills-devshell/` sub-flake and reinstalls its skills.
