# Minimal home-manager option surface for evalModules tests. Provides just
# enough of `home.*` for the module's option declarations and
# `home.activation` writes to resolve without pulling in real home-manager.
# Pair with `mock-home-manager-lib.nix` via specialArgs to provide the
# `lib.hm.dag.entryAfter` stand-in.
{ lib, ... }:
{
  options = {
    home.homeDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/home/test";
    };
    home.packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
    };
    home.activation = lib.mkOption {
      # `data` is what `lib.hm.dag.entryAfter` puts the script text into;
      # tests assert on it directly.
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.data = lib.mkOption { type = lib.types.str; };
          options.after = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
          options.before = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
        }
      );
      default = { };
    };
  };
}
