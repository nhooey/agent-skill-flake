# nix-darwin shim: forwards `services.agent-skill-flake.*` into the home-manager
# module under `home-manager.users.<user>.programs.agent-skill-flake.*`.
#
# The activation itself lives in the home-manager module (see
# `home-manager-module.nix`) — `system.userActivationScripts`, the previous
# integration point, was removed in nix-darwin 25.05, and the activation is
# inherently per-user anyway. This shim exists so darwin configurations can
# wire agent-skill-flake with one import.
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
#     inputs.agent-skill-flake.darwinModules.default
#     {
#       services.agent-skill-flake = {
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
  cfg = config.services.agent-skill-flake;
in
{
  options.services.agent-skill-flake = {
    enable = lib.mkEnableOption "agent-skill-flake user-activation hook (via home-manager)";

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
        `services.agent-skill-flake.enable = true`.
      '';
    };
  }
  # The data options forwarded verbatim into the home-manager module
  # (`skills`, `autoDiscover`, `agent`, `scope`, `root`) — shared so the
  # shim's option types stay in lockstep with what it forwards into.
  // import ./lib/options-agent-skill-flake.nix { inherit lib; };

  config = lib.mkIf cfg.enable (
    let
      resolvedUser = lib.throwIf (cfg.user == null || cfg.user == "") ''
        services.agent-skill-flake.user resolved to null/empty. Either
        set `system.primaryUser` in your nix-darwin configuration,
        or pass `services.agent-skill-flake.user = "<username>";`
        explicitly. The activation is per-user, so the module needs
        to know which user's home-manager session to attach to.
      '' cfg.user;
    in
    {
      home-manager.users.${resolvedUser} = {
        imports = [ (import ./home-manager-module.nix { inherit self nixpkgs; }) ];
        programs.agent-skill-flake = {
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
