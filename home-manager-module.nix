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
#     imports = [ inputs.agent-skill-flake.homeManagerModules.default ];
#     programs.agent-skill-flake = {
#       enable = true;
#       scope  = "personal";
#       skills = [ inputs.my-skills.packages.${pkgs.system}.skill-foo ];
#     };
#
# nix-darwin / NixOS consumers should import the system-level shim
# (`darwinModules.default` / `nixosModules.default`) instead — it forwards
# `services.agent-skill-flake.*` to this module under `home-manager.users.<user>`.
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

  cfg = config.programs.agent-skill-flake;
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
        programs.agent-skill-flake.scope = "custom" requires
        programs.agent-skill-flake.root = "<path>".
      '' "--scope=custom --root=${lib.escapeShellArg (cfg.root or "")}")
    else
      (lib.throwIf (cfg.root != null) ''
        programs.agent-skill-flake.root is only valid when scope = "custom"
        (got scope = ${builtins.toJSON cfg.scope}).
      '' "--scope=${cfg.scope}");
in
{
  options.programs.agent-skill-flake = {
    enable = lib.mkEnableOption "agent-skill-flake home-manager activation hook";
  }
  // import ./lib/options-agent-skill-flake.nix { inherit lib; };

  config = lib.mkIf cfg.enable {
    home.activation.flakeSkillsReconcile = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${reconcile}/bin/reconcile-home-manager ${scopeArgs}
      ${reap}/bin/reap-home-manager ${scopeArgs}
    '';
  };
}
