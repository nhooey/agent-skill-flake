{
  nixpkgs,
  skillsDir,
  systems ? [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ],
  name ? "claude-skills-all",
  installRoot ? "$HOME/.claude/skills",
  envVarOverride ? "CLAUDE_SKILLS_DIR",
  # Injected by lib/default.nix from this flake's `self`. Same role as in
  # mk-skill-flake.nix.
  provenance,
}:
let
  internal = import ./internal.nix { inherit nixpkgs; };
  inherit (nixpkgs) lib;

  forAllSystems = f: lib.genAttrs systems (system: f system);

  discovered = internal.discoverSkills skillsDir;

  skillSetFor =
    system:
    map (s: {
      inherit (s) name;
      drv = internal.mkSkill system { inherit (s) name src; inherit provenance; };
    }) discovered;

  aggregateFor =
    system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      skillSet = skillSetFor system;
    in
    pkgs.symlinkJoin {
      inherit name;
      paths = map (s: s.drv) skillSet;
    };

  installerFor =
    system:
    internal.mkInstaller system {
      appName = name;
      skills = skillSetFor system;
      inherit installRoot envVarOverride;
    };

  previewFor =
    system:
    internal.mkPreview system {
      appName = name;
      displayName = name;
      skills = skillSetFor system;
      inherit installRoot envVarOverride;
    };
in
{
  packages = forAllSystems (
    system:
    let
      perSkill = lib.listToAttrs (
        map (s: {
          inherit (s) name;
          value = s.drv;
        }) (skillSetFor system)
      );
    in
    perSkill
    // {
      default = aggregateFor system;
      all = aggregateFor system;
    }
  );

  apps = forAllSystems (system: {
    default = {
      type = "app";
      program = "${previewFor system}/bin/preview-${name}";
    };
    install = {
      type = "app";
      program = "${installerFor system}/bin/install-${name}";
    };
    preview = {
      type = "app";
      program = "${previewFor system}/bin/preview-${name}";
    };
  });
}
