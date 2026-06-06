# flake-parts module: the agent-skill-flake dev-shell wiring, factored out.
#
# WHY THIS EXISTS
# ~10 consumer repos hand-roll the *identical* numtide/devshell wiring:
#   - a `name` + a stock motd ("🚀 Entering <name> dev shell / Run menu …"),
#   - a `devshell.startup.install-skills.text` that reconciles a runtime
#     `skills-devshell/` sub-flake (`nix run "$PRJ_ROOT/<dir>#reconcile" …`),
#   - the ci/dev/maintenance command trio (check / fmt / update-flake),
#   - the two `skills`-category commands (reap-skills / update-skills-devshell).
# Every copy drifts independently. This module collapses that boilerplate to
#   imports = [ inputs.agent-skill-flake.flakeModules.devshellSkills ];
#   agent-skill-flake.devshellSkills = { name = "my-repo"; };
# and nothing else.
#
# SCOPE: dev-shell wiring ONLY — motd, the install-skills startup, and the
# standard/skills command lists. treefmt is deliberately NOT bundled: real
# consumers diverge on it (nixfmt+shfmt+excludes here, +yamlfmt/prettier
# elsewhere), so folding it in would force every consumer into an override.
#
# CONSUMER CONTRACT
#   - Override the scalar `name`/`motd` via the options below (they are set
#     with `lib.mkDefault`, so a plain `devshells.default.name = …` also wins).
#   - Add repo-specific `packages`/`commands` by setting them directly on
#     `perSystem.devshells.default.{packages,commands}` — devshell list options
#     merge by concatenation, so no extra option is needed for that; this
#     module's standard + skills commands and the consumer's own commands all
#     end up in the same menu.
#   - DROP any `inputs.devshell.flakeModule` the consumer imports themselves:
#     the exported bundle already provides devshell, so importing a second,
#     differently-pinned devshell flakeModule loads both and merges
#     `devshells.default` (redundant at best, version-skew at worst).
#
# The actual command/startup strings come from ./devshell-skills-hook.nix (this
# module's sibling). Importing it by relative path means it resolves to
# agent-skill-flake's OWN store path even when a consumer imports this module,
# so the runtime `nix run "$PRJ_ROOT/<dir>#…"` snippets stay identical across
# every consumer instead of being re-derived per repo.
{
  config,
  lib,
  ...
}:
let
  cfg = config.agent-skill-flake.devshellSkills;

  # The stock motd, generated from `name` when the consumer leaves `motd` null.
  # Kept byte-for-byte identical to the copy every repo hand-rolls today.
  defaultMotd = ''
    {bold}{14}🚀 Entering ${cfg.name} dev shell{reset}
    Run {bold}menu{reset} to list available commands.
  '';
in
{
  options.agent-skill-flake.devshellSkills = {
    name = lib.mkOption {
      type = lib.types.str;
      default = "dev shell";
      description = ''
        The devShell `name` and the label spliced into the generated motd
        ("🚀 Entering <name> dev shell"). Override per repo.
      '';
    };

    motd = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The full devshell motd string. When null (the default) the standard
        motd is generated from `name`. Set it to take full control of the
        banner.
      '';
    };

    dir = lib.mkOption {
      type = lib.types.str;
      default = "skills-devshell";
      description = ''
        Sub-flake directory (relative to `$PRJ_ROOT`) reconciled on `nix
        develop` and targeted by the skills commands. Passed straight to the
        devshell-skills hook.
      '';
    };

    scope = lib.mkOption {
      type = lib.types.str;
      default = "project";
      description = ''
        Install scope passed to the reconcile / removal apps (`--scope=<scope>`).
      '';
    };

    reconcileApp = lib.mkOption {
      type = lib.types.str;
      default = "reconcile";
      description = ''
        App in the `<dir>` sub-flake run on `nix develop` to converge the
        skill set (install + update + sweep strays this owner left).
      '';
    };

    removeApp = lib.mkOption {
      type = lib.types.str;
      default = "purge";
      description = ''
        App in the `<dir>` sub-flake the `reap-skills` command invokes to
        remove the whole set.
      '';
    };

    includeStandardCommands = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to prepend the repo-agnostic ci/dev/maintenance trio
        (check / fmt / update-flake) to the devShell command list. The two
        `skills`-category commands are always included.
      '';
    };
  };

  config = {
    perSystem =
      { ... }:
      let
        # The pure hook: the runtime `nix run "$PRJ_ROOT/<dir>#…"` startup
        # snippet, the two skills commands, and the standard command trio.
        devshellSkills = import ./devshell-skills-hook.nix {
          inherit (cfg)
            dir
            scope
            reconcileApp
            removeApp
            ;
        };
      in
      {
        devshells.default = {
          # Scalars use mkDefault so a consumer can still override name/motd
          # with a plain assignment on `devshells.default`.
          name = lib.mkDefault cfg.name;
          motd = lib.mkDefault (if cfg.motd != null then cfg.motd else defaultMotd);

          # Reconcile the runtime skills-devshell sub-flake on `nix develop`.
          devshell.startup.install-skills.text = devshellSkills.startup;

          # Standard trio (optional) ++ the two skills commands. This is a list
          # option, so a consumer's own `devshells.default.commands` concatenate
          # onto these rather than replacing them.
          commands =
            (lib.optionals cfg.includeStandardCommands devshellSkills.standardCommands)
            ++ devshellSkills.commands;
        };
      };
  };
}
