# nix-darwin module that runs reconcile + reap during user activation.
#
# Usage in a darwin config:
#
#   inputs.flake-skills.url = "github:nhooey/flake-skills";
#   modules = [
#     inputs.flake-skills.darwinModules.default
#     {
#       services.flake-skills.enable = true;
#       # `skills` defaults to auto-discovery via passthru.isFlakeSkill over
#       # environment.systemPackages — set explicitly to override.
#     }
#   ];
#
# After `darwin-rebuild switch`, every declared skill ends up symlinked at
# $HOME/.claude/skills/<name>, with GC roots and the aggregate lock
# (`.flake-skills-lock.json`) updated. Stray managed entries are swept;
# broken symlinks are reaped. No manual `nix run #install` needed.
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

  cfg = config.services.flake-skills;
  system = pkgs.stdenv.hostPlatform.system;

  # Default skill set: every derivation in environment.systemPackages
  # marked by mkSkill's passthru.isFlakeSkill.
  autoDiscovered = lib.filter (
    p:
    lib.isDerivation p
    && (p.passthru or { }) ? isFlakeSkill
    && p.passthru.isFlakeSkill
  ) config.environment.systemPackages;

  # mkReconcile expects `[{name; drv}]` records keyed by the bare skill
  # name (the on-disk `~/.claude/skills/<name>` directory).
  skillRecords = map (drv: {
    name = drv.passthru.flakeSkillName;
    inherit drv;
  }) cfg.skills;

  reconcile = internal.mkReconcile system {
    appName = "darwin";
    skills = skillRecords;
    inherit (flakeLib) provenance;
    inherit (cfg) installRoot envVarOverride;
  };

  reap = internal.mkReap system {
    appName = "darwin";
    inherit (flakeLib) provenance;
    inherit (cfg) installRoot envVarOverride;
  };
in
{
  options.services.flake-skills = {
    enable = lib.mkEnableOption "flake-skills user-activation hook";

    skills = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = autoDiscovered;
      defaultText = lib.literalExpression ''
        lib.filter (p: p ? passthru.isFlakeSkill && p.passthru.isFlakeSkill)
                   config.environment.systemPackages
      '';
      description = ''
        Skill packages to reconcile during user activation. Each must be a
        derivation produced by flake-skills' `mkSkill` (carrying
        `passthru.isFlakeSkill = true`). Defaults to auto-discovery over
        `environment.systemPackages`; override to declare a different
        explicit set.
      '';
    };

    installRoot = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.claude/skills";
      description = ''
        Where to symlink reconciled skills. Defaults to `~/.claude/skills`
        (the literal string is expanded by the activation shell, so
        `$HOME` resolves at run time).
      '';
    };

    envVarOverride = lib.mkOption {
      type = lib.types.str;
      default = "CLAUDE_SKILLS_DIR";
      description = ''
        Env var that overrides `installRoot` at run time. Must match the
        var the rest of flake-skills' apps look at, otherwise reconcile and
        ad-hoc `nix run #install` will disagree on the install location.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    system.userActivationScripts.flakeSkillsReconcile.text = ''
      ${reconcile}/bin/reconcile-darwin
      ${reap}/bin/reap-darwin
    '';
  };
}
