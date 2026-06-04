# Shared option declarations for the flake-skills consumer modules.
#
# Both the home-manager module (`programs.flake-skills.*`) and the
# nix-darwin shim (`services.flake-skills.*`, which forwards values into
# the home-manager module) expose the same five data options. Defining
# their types / defaults / docs once here keeps the two surfaces from
# drifting — the darwin shim forwards these values verbatim, so its option
# types MUST match home-manager's exactly.
#
# `enable` is intentionally left to each module (the wording differs by
# context), and the darwin shim adds its own `user` option.
{ lib }:
{
  skills = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [ ];
    example = lib.literalExpression ''
      [
        inputs.my-skills.packages.''${pkgs.system}.agent-skill-foo
      ]
    '';
    description = ''
      Skill (or skills-env) derivations to reconcile on activation.
      Each must be either:

        • a single skill produced by `mkSkillFlake` /
          `mkAllSkillsFlake` (carrying `passthru.isFlakeSkill = true`
          and `passthru.flakeSkillName`), or

        • a multi-skill env produced by `mkSkillsEnv` (carrying
          `passthru.isFlakeSkillsEnv = true` and
          `passthru.flakeSkillsEnv`), which is expanded back into its
          member skills on activation.
    '';
  };

  autoDiscover = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      When `true`, also reconcile every flake-skills-tagged package in
      `home.packages` (in addition to whatever is listed in `skills`).
      Mirrors the auto-discovery the deprecated darwin module did over
      `environment.systemPackages`. Off by default — consumers usually
      prefer a single explicit `skills` list as the source of truth.
    '';
  };

  agent = lib.mkOption {
    type = lib.types.str;
    default = "claude-code";
    example = "codex";
    description = ''
      Which agent's filesystem layout to target. Each profile in
      `lib/agent-profiles.nix` names per-scope install suffixes
      (`$HOME/<personalSuffix>` and
      `<project-root>/<projectSuffix>`). Currently supports
      `claude-code`, `codex`, `cursor`. Throws at eval if the name
      isn't a known profile.
    '';
  };

  scope = lib.mkOption {
    type = lib.types.enum [
      "personal"
      "project"
      "custom"
    ];
    example = "personal";
    description = ''
      Install scope — **required**, no default.

        • `personal` → `$HOME/<agent.personalSuffix>`
        • `project`  → `<project-root>/<agent.projectSuffix>`,
          walking up from `$PWD` at activation time for the nearest
          `.git/` (preferred) or `flake.nix` (fallback). Hard error
          if no project root is found.
        • `custom`   → the literal `root` option (must be set).

      Home-manager activations almost always want `personal`.
    '';
  };

  root = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "/etc/agent-skills";
    description = ''
      Required when `scope = "custom"`. The literal install
      directory; passed verbatim to the reconcile/reap apps as
      `--root=<path>`. Ignored for other scopes.
    '';
  };
}
