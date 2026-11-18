# The shared skill checks, `skill-layout` and `skill-description`, which
# lib/skill-checks-flake-module.nix hands every flake that imports
# `flakeModules.devshellSkills`. Each runs a script from lib/bash/ on the
# repository's skills folder, with the settings of lib/config/skill-checks.toml
# under the repository's own `skill-checks.toml`.
{ pkgs }:
let
  inherit (pkgs) lib;

  defaults = builtins.fromTOML (builtins.readFile ./config/skill-checks.toml);

  # `over` merged onto `base` key by key: tables merge, and any other value
  # replaces the default whole. A key `base` lacks, or a value of another
  # type than the default's, is an error naming the key.
  merge =
    where: base: over:
    base
    // lib.mapAttrs (
      key: value:
      let
        at = "${where}${key}";
        expected = builtins.typeOf base.${key};
      in
      if !(base ? ${key}) then
        throw "skill-checks.toml: `${at}` is no setting of the skill checks"
      else if builtins.typeOf value != expected then
        throw "skill-checks.toml: `${at}` is a ${builtins.typeOf value}, not a ${expected}"
      else if builtins.isAttrs value then
        merge "${at}." base.${key} value
      else
        value
    ) over;

  # The folders directly in `path`, leaving out hidden ones and Python's
  # caches; none when `path` doesn't exist.
  foldersIn =
    path:
    lib.optionals (builtins.pathExists path) (
      lib.attrNames (
        lib.filterAttrs (
          name: type: type == "directory" && !(lib.hasPrefix "." name) && name != "__pycache__"
        ) (builtins.readDir path)
      )
    );

  # The `skillName` a skill's own flake.nix hands `mkSkillFlake`, read by
  # calling its `outputs` with a `mkSkillFlake` that returns its arguments
  # as they are; null when that yields no string. Its other inputs are
  # empty sets, so an `outputs` that reads anything from them, or names
  # agent-skill-flake's input otherwise, stops the whole evaluation:
  # `tryEval` catches only `throw` and `assert`. The README states the form
  # the `skill-flake` rule reads.
  skillNameInFlake =
    file:
    let
      outputs = (import file).outputs or null;
      stubs = {
        self = { };
        nixpkgs = { };
        agent-skill-flake.lib.mkSkillFlake = args: args;
      };
      wanted = builtins.functionArgs outputs;
      inputs = if wanted == { } then stubs else lib.mapAttrs (name: _: stubs.${name} or { }) wanted;
      read = builtins.tryEval (
        let
          name = (outputs inputs).skillName or null;
        in
        if builtins.isString name then name else null
      );
    in
    if builtins.isFunction outputs && read.success then read.value else null;

  programs = {
    skill-layout = pkgs.writeShellApplication {
      name = "skill-layout-check";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.findutils
        pkgs.jq
        # The Python pylint runs on, for its tokenize.
        pkgs.python3
        pkgs.fawltydeps
        pkgs.pylint
        pkgs.ruff
      ];
      # Interpolated, so each file is copied to the store and the program
      # depends on it.
      runtimeEnv = {
        SKILL_CHECKS_PYLINTRC = "${./config/skill-checks-pylintrc}";
        SKILL_CHECKS_RUFF = "${./config/skill-checks-ruff.toml}";
      };
      text = builtins.readFile ./bash/skill-layout-check.sh;
    };
    skill-description = pkgs.writeShellApplication {
      name = "skill-description-check";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.jq
        pkgs.yq-go
        pkgs.lychee
      ];
      text = builtins.readFile ./bash/skill-description-check.sh;
    };
  };

  # The section of skill-checks.toml each check takes its settings from.
  sections = {
    skill-layout = "layout";
    skill-description = "description";
  };

  # Everything the checks need from the repository whose root is `root`: a
  # path, or a flake's `self`.
  forRepository =
    root:
    let
      rootPath = if builtins.isAttrs root then root.outPath else root;
      at = sub: rootPath + "/${sub}";

      settingsFile = at "skill-checks.toml";
      settings = merge "" defaults (
        lib.optionalAttrs (builtins.pathExists settingsFile) (
          builtins.fromTOML (builtins.readFile settingsFile)
        )
      );

      # A repository without a skills folder gets no check. One whose skills
      # folder holds no skill, such as one kept with only a .gitkeep, gets
      # both, and each fails on the `skills-exist` rule.
      skillsPath = at settings.skills-dir;
      hasSkillsFolder = builtins.pathExists skillsPath;

      # The skills folder alone in the store, so a check reruns only when a
      # skill changes.
      skills = builtins.path {
        path = skillsPath;
        name = "skills";
      };

      # What the scripts can't see in the skills folder: the folders in the
      # repository's tests/, and the `skillName` of each skill's own
      # flake.nix, read only when the `skill-flake` rule is on.
      repository = {
        tests = foldersIn (at "tests");
        skill-flakes = lib.optionalAttrs settings.description.skill-flake (
          lib.genAttrs (lib.filter (name: builtins.pathExists (skillsPath + "/${name}/flake.nix")) (
            foldersIn skillsPath
          )) (name: skillNameInFlake (skillsPath + "/${name}/flake.nix"))
        );
      };

      input = pkgs.writeText "skill-checks.json" (builtins.toJSON (settings // { inherit repository; }));

      check =
        name:
        pkgs.runCommand "${name}-check" { } ''
          ${lib.getExe programs.${name}} --settings ${input} ${skills}
          touch "$out"
        '';
    in
    {
      inherit settings input skills;
      checks = lib.genAttrs (lib.filter (name: hasSkillsFolder && settings.${sections.${name}}.enable) (
        lib.attrNames sections
      )) check;
    };
in
{
  inherit defaults programs forRepository;
}
