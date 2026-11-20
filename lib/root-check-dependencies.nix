# The `root-check-dependencies` command: roots a repository's check
# dependencies under one indirect GC root, so garbage collection keeps them
# while the repository still uses them. See ./bash/root-check-dependencies.sh
# and ./check-dependencies.nix.
{ pkgs, system }:
pkgs.writeShellApplication {
  name = "root-check-dependencies";
  # `nix` and `nix-store` come from the caller's PATH, so they match the
  # store and daemon the dev shell already uses.
  runtimeInputs = [
    pkgs.coreutils
    pkgs.git
  ];
  text = ''
    ROOT_CHECK_DEPENDENCIES_SYSTEM=${system}
    ROOT_CHECK_DEPENDENCIES_EXPR=${./check-dependencies.nix}
  ''
  + builtins.readFile ./bash/root-check-dependencies.sh;
}
