# Minimal mock of nix-darwin's `home-manager.users` namespace plus
# `system.primaryUser` (which the shim's `user` option defaults from).
# Captures whatever the shim writes so tests can inspect it.
{ lib, ... }:
{
  options = {
    home-manager.users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.unspecified);
      default = { };
    };
    system.primaryUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  };
}
