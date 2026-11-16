# The repository's own command-line tools, put on the dev shell's PATH by
# flake.nix and exercised by checks.nix. Each script lives in its own file
# so editors and shellcheck see it as shell.
{ pkgs }:
{
  # Uses the caller's nix rather than pinning one, so it talks to the same
  # daemon and store as the rest of the shell.
  flake-checks = pkgs.writeShellApplication {
    name = "flake-checks";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
      pkgs.gnused
    ];
    meta = {
      description = "List this flake's checks and build them one at a time.";
      mainProgram = "flake-checks";
    };
    text = builtins.readFile ./flake-checks.bash;
  };
}
