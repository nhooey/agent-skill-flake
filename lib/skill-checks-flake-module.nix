# flake-parts module: the shared skill checks, `checks.<system>.skill-layout`
# and `checks.<system>.skill-description`, run on the importing flake's own
# skills folder with the settings of its `skill-checks.toml` (see the
# README's "Skill checks" section). It is part of `flakeModules.devshellSkills`,
# so every skill repository that imports that module gets the checks; a flake
# without a skills folder gets none.
{ self, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks = ((import ./skill-checks.nix { inherit pkgs; }).forRepository self).checks;
    };
}
