# nix-darwin shim: forwards `services.flake-skills.*` into the home-manager
# module under `home-manager.users.<user>.programs.flake-skills.*`.
#
# The activation itself lives in the home-manager module (see
# `home-manager-module.nix`) — `system.userActivationScripts`, the previous
# integration point, was removed in nix-darwin 25.05, and the activation is
# inherently per-user anyway. This shim exists so darwin configurations can
# wire flake-skills with one import.
#
# Requires home-manager's nix-darwin integration
# (`inputs.home-manager.darwinModules.home-manager`) to be imported by the
# consumer. Without it, `home-manager.users` is undefined and evaluation
# fails with a clear "option not found" error.
#
# Usage:
#
#   modules = [
#     inputs.home-manager.darwinModules.home-manager
#     inputs.flake-skills.darwinModules.default
#     {
#       services.flake-skills = {
#         enable = true;
#         user   = "alice";
#         scope  = "personal";
#         skills = [ inputs.my-skills.packages.aarch64-darwin.skill-foo ];
#       };
#     }
#   ];
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
  cfg = config.services.flake-skills;
in
{
  options.services.flake-skills = {
    enable = lib.mkEnableOption "flake-skills user-activation hook (via home-manager)";

    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = config.system.primaryUser or null;
      defaultText = lib.literalExpression "config.system.primaryUser";
      example = "alice";
      description = ''
        The home-manager user this module configures. Defaults to
        `system.primaryUser` (the nix-darwin convention for "whoever
        owns this machine"); override to target a different user, or
        set explicitly when `system.primaryUser` isn't configured.
        Must resolve to a non-null, non-empty string when
        `services.flake-skills.enable = true`.
      '';
    };

    skills = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Forwarded to `programs.flake-skills.skills`.";
    };

    autoDiscover = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Forwarded to `programs.flake-skills.autoDiscover`.";
    };

    agent = lib.mkOption {
      type = lib.types.str;
      default = "claude-code";
      description = "Forwarded to `programs.flake-skills.agent`.";
    };

    scope = lib.mkOption {
      type = lib.types.enum [
        "personal"
        "project"
        "custom"
      ];
      example = "personal";
      description = "Forwarded to `programs.flake-skills.scope`. Required.";
    };

    root = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Forwarded to `programs.flake-skills.root`. Required iff `scope = \"custom\"`.";
    };
  };

  config = lib.mkIf cfg.enable (
    let
      resolvedUser =
        lib.throwIf (cfg.user == null || cfg.user == "") ''
          services.flake-skills.user resolved to null/empty. Either
          set `system.primaryUser` in your nix-darwin configuration,
          or pass `services.flake-skills.user = "<username>";`
          explicitly. The activation is per-user, so the module needs
          to know which user's home-manager session to attach to.
        '' cfg.user;
    in
    {
      home-manager.users.${resolvedUser} = {
        imports = [ (import ./home-manager-module.nix { inherit self nixpkgs; }) ];
        programs.flake-skills = {
          enable = true;
          inherit (cfg)
            skills
            autoDiscover
            agent
            scope
            root
            ;
        };
      };
    }
  );
}
