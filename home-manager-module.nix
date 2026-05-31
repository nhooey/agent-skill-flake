# home-manager module: reconcile + reap on home-manager activation.
#
# The activation is inherently per-user
# ($HOME/<profile.personalSuffix>, /nix/var/nix/gcroots/per-user/$USER),
# so home-manager's `home.activation` is the natural execution context —
# it works in standalone home-manager, under nix-darwin (via
# home-manager.users.<user>), and under NixOS the same way.
#
# Usage in standalone home-manager:
#
#     imports = [ inputs.flake-skills.homeManagerModules.default ];
#     programs.flake-skills = {
#       enable = true;
#       scope  = "personal";
#       skills = [ inputs.my-skills.packages.${pkgs.system}.skill-foo ];
#     };
#
# nix-darwin / NixOS consumers should import the system-level shim
# (`darwinModules.default` / `nixosModules.default`) instead — it forwards
# `services.flake-skills.*` to this module under `home-manager.users.<user>`.
{
  self,
  nixpkgs,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  internal = import ./lib/internal.nix { inherit nixpkgs; };
  flakeLib = import ./lib { inherit self; };

  cfg = config.programs.flake-skills;
  system = pkgs.stdenv.hostPlatform.system;

  profile = internal.resolveAgentProfile cfg.agent;

  # Accept both single skills (mkSkillFlake — `passthru.isFlakeSkill`)
  # and multi-skill envs (mkSkillsEnv — `passthru.isFlakeSkillsEnv`).
  isFlakeSkillEntry =
    p:
    lib.isDerivation p
    && (
      ((p.passthru or { }) ? isFlakeSkill && p.passthru.isFlakeSkill)
      || ((p.passthru or { }) ? isFlakeSkillsEnv && p.passthru.isFlakeSkillsEnv)
    );

  autoDiscovered = lib.filter isFlakeSkillEntry config.home.packages;

  effectiveSkills = cfg.skills ++ (if cfg.autoDiscover then autoDiscovered else [ ]);

  # Expand each entry into one-or-more `{name; drv}` records. A single
  # skill becomes a 1-element list; a `mkSkillsEnv` becomes its member
  # list as-is (so each member installs to its own
  # `<install-root>/<flakeSkillName>/` directory, not to a nested
  # subtree under the env's name).
  expandSkill =
    drv:
    if drv.passthru.isFlakeSkillsEnv or false then
      drv.passthru.flakeSkillsEnv
    else
      [
        {
          name = drv.passthru.flakeSkillName;
          inherit drv;
        }
      ];

  skillRecords = lib.concatMap expandSkill effectiveSkills;

  reconcile = internal.mkReconcile system {
    appName = "home-manager";
    skills = skillRecords;
    inherit (flakeLib) provenance;
    inherit profile;
  };

  reap = internal.mkReap system {
    appName = "home-manager";
    inherit (flakeLib) provenance;
    inherit profile;
  };

  # The activation forwards the user's scope choice through to the
  # generated bash apps as explicit flags — no env vars, no implicit
  # defaults. Scope=custom requires `root`; the `throwIf` guards below
  # catch the mis-pairing at eval time. Using throwIf rather than the
  # NixOS-style `assertions` list keeps the module portable to evalModules
  # contexts that don't load the assertion-handling module.
  scopeArgs =
    if cfg.scope == "custom" then
      (lib.throwIf (cfg.root == null || cfg.root == "") ''
        programs.flake-skills.scope = "custom" requires
        programs.flake-skills.root = "<path>".
      '' "--scope=custom --root=${lib.escapeShellArg (cfg.root or "")}")
    else
      (lib.throwIf (cfg.root != null) ''
        programs.flake-skills.root is only valid when scope = "custom"
        (got scope = ${builtins.toJSON cfg.scope}).
      '' "--scope=${cfg.scope}");
in
{
  options.programs.flake-skills = {
    enable = lib.mkEnableOption "flake-skills home-manager activation hook";

    skills = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression ''
        [
          inputs.my-skills.packages.''${pkgs.system}.skill-foo
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
  };

  config = lib.mkIf cfg.enable {
    home.activation.flakeSkillsReconcile = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${reconcile}/bin/reconcile-home-manager ${scopeArgs}
      ${reap}/bin/reap-home-manager ${scopeArgs}
    '';
  };
}
