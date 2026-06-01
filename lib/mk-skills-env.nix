# Bundle several already-built skill derivations into a single
# environment-style derivation, the same way `pkgs.buildEnv` /
# `pkgs.symlinkJoin` combine packages into one filesystem tree.
#
# Why this exists: `programs.flake-skills.skills` is a flat list of
# packages. Without a multi-skill carrier, consumers either list 11
# skills inline at every call site or hand-roll a `symlinkJoin` whose
# `passthru` is empty and breaks the reconcile loop ("attribute
# 'flakeSkillName' missing"). This helper produces a drv that:
#
#   • is `nix run`/`nix build`-runnable like any other package, so
#     `nix run github:owner/repo#agent-skills-foo-all` still yields an
#     on-disk tree under `share/claude-skills/<each-skill>/`, and
#
#   • carries `passthru.isFlakeSkillsEnv = true` and
#     `passthru.flakeSkillsEnv = [{ name; drv; }]` so the
#     home-manager-module expands the env back into per-skill
#     records on activation, with each member installed under its
#     own `~/.claude/skills/<flakeSkillName>/` directory.
#
# Members are real `mkSkill` outputs (carrying their own
# `passthru.flakeSkillName`); the env is just a wrapper that lets a
# pre-curated list of them travel as a single package attribute.
#
# Usage:
#
#   flake-skills.lib.mkSkillsEnv {
#     pkgs = nixpkgs.legacyPackages.${system};
#     name = "agent-skills-git-all";
#     skills = map (n: base.packages.${system}."agent-skill-${n}") [
#       "git-branch-naming"
#       "git-commit-message-format"
#       # ...
#     ];
#   }
{ }:
{
  # Nixpkgs instance for the target system. Used for `symlinkJoin`.
  pkgs,
  # Derivation name (also the package attribute key consumers expose).
  name,
  # List of skill derivations produced by `mkSkillFlake` /
  # `mkAllSkillsFlake`. Each must carry `passthru.flakeSkillName`.
  skills,
}:
let
  members = map (drv: {
    name =
      drv.passthru.flakeSkillName or (throw ''
        mkSkillsEnv '${name}': every member of `skills` must be a
        derivation produced by flake-skills' `mkSkillFlake` /
        `mkAllSkillsFlake` (carrying `passthru.flakeSkillName`). Got
        a derivation without that attribute; if you're trying to nest
        a `mkSkillsEnv` inside another, inline the member skills
        instead — nested envs aren't supported.
      '');
    inherit drv;
  }) skills;
in
pkgs.symlinkJoin {
  inherit name;
  paths = skills;
  passthru = {
    isFlakeSkillsEnv = true;
    flakeSkillsEnv = members;
  };
}
