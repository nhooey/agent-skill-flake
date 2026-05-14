# home-manager module: reconcile + reap on home-manager activation.
#
# The activation is inherently per-user ($HOME/.claude/skills,
# /nix/var/nix/gcroots/per-user/$USER), so home-manager's `home.activation`
# is the natural execution context — it works in standalone home-manager,
# under nix-darwin (via home-manager.users.<user>), and under NixOS the
# same way. The previous `darwin-module.nix` wrote into
# `system.userActivationScripts`, which was removed in nix-darwin 25.05
# and only ever ran in the user's session anyway.
#
# Usage in standalone home-manager:
#
#     imports = [ inputs.flake-skills.homeManagerModules.default ];
#     programs.flake-skills = {
#       enable = true;
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

  isSkill =
    p:
    lib.isDerivation p
    && (p.passthru or { }) ? isFlakeSkill
    && p.passthru.isFlakeSkill;

  autoDiscovered = lib.filter isSkill config.home.packages;

  effectiveSkills = cfg.skills ++ (if cfg.autoDiscover then autoDiscovered else [ ]);

  # mkReconcile expects `[{name; drv}]` records keyed by the bare skill
  # name (the on-disk `~/.claude/skills/<name>` directory).
  skillRecords = map (drv: {
    name = drv.passthru.flakeSkillName;
    inherit drv;
  }) effectiveSkills;

  reconcile = internal.mkReconcile system {
    appName = "home-manager";
    skills = skillRecords;
    inherit (flakeLib) provenance;
    inherit (cfg) installRoot envVarOverride;
  };

  reap = internal.mkReap system {
    appName = "home-manager";
    inherit (flakeLib) provenance;
    inherit (cfg) installRoot envVarOverride;
  };
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
        Skill derivations to reconcile on activation. Each must be a
        derivation produced by flake-skills' `mkSkill` (carrying
        `passthru.isFlakeSkill = true` and `passthru.flakeSkillName`).
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

    installRoot = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.claude/skills";
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/.claude/skills"'';
      description = ''
        Directory to reconcile skills into. Defaults to
        `~/.claude/skills` resolved at evaluation time via
        `config.home.homeDirectory`.
      '';
    };

    envVarOverride = lib.mkOption {
      type = lib.types.str;
      default = "CLAUDE_SKILLS_DIR";
      description = ''
        Env var that overrides `installRoot` at run time. Must match the
        var the rest of flake-skills' apps look at, otherwise reconcile
        and ad-hoc `nix run #install` will disagree on the install
        location.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.activation.flakeSkillsReconcile = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${reconcile}/bin/reconcile-home-manager
      ${reap}/bin/reap-home-manager
    '';
  };
}
