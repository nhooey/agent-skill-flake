# Root-side wiring for a `skills-devshell/` sub-flake invoked at runtime.
# Returns the dev-shell startup snippet plus the whole `skills`-category
# `commands` list, so the `nix run "$PRJ_ROOT/<dir>#<app>"` strings AND the
# repo-agnostic command definitions live in one place instead of being
# hand-rolled (and drifting) per repo.
#
# Assumes numtide/devshell, which exports `$PRJ_ROOT` (the project root) into
# the shell; the sub-flake directory is resolved relative to it, so the hook
# works regardless of the caller's CWD. Invoking the sub-flake by path keeps it
# out of the root flake's input graph — that is the whole point.
{
  # Sub-flake directory name, relative to the project root.
  dir ? "skills-devshell",
  # Install scope passed to the reconcile / removal apps.
  scope ? "project",
  # App that converges the target to the declared set (install + update +
  # sweep strays this owner left).
  reconcileApp ? "reconcile",
  # App that removes the whole set. `purge` deletes every skill the
  # combination's appName owns — the "reap it all" verb. (`reap` only prunes
  # broken/stale symlinks, so it is NOT the full-removal default here.)
  removeApp ? "purge",
  # Arguments added to every run of the reconcile app (on `nix develop`, and
  # by `reconcile-skills` and `update-skills-devshell`), such as
  # `[ "--strict" ]` to fail when a skill differs from the personal scope's
  # copy, or `[ "--ignore-personal-scope" ]` to skip that comparison.
  reconcileArgs ? [ ],
}:
let
  quote = arg: "'" + builtins.replaceStrings [ "'" ] [ "'\\''" ] arg + "'";
  reconcileFlags = builtins.concatStringsSep "" (map (arg: " " + quote arg) reconcileArgs);
  # The command a reconcile names for bringing the project's skills up to
  # date, when one differs from the personal scope's copy. An environment
  # variable rather than a flag, so a sub-flake still locked to a reconcile
  # that predates it runs as before.
  updateEnv = "AGENT_SKILL_FLAKE_PROJECT_UPDATE_COMMAND=update-skills-devshell ";
  run = app: ''nix run "$PRJ_ROOT/${dir}#${app}" -- --scope=${scope}'';
  # Commands find the project root each time they run: `$PRJ_ROOT` is fixed
  # when the dev shell is entered, so a command run from another checkout
  # (a git worktree, or a `cd` in a child process) would act on the first.
  # Outside git, `$PRJ_ROOT` is the only root there is.
  findRoot = "root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$PRJ_ROOT";
  runHere = app: ''nix run "$root/${dir}#${app}" -- --scope=${scope}'';
  # The command's own arguments go through to the app, so e.g.
  # `reap-skills --yes` reaches purge (which refuses without a TTY otherwise).
  runHereWithArgs = app: ''${runHere app} "$@"'';
in
{
  # Splice into `devshell.startup.<name>.text` (reconcile on `nix develop`).
  startup = "${updateEnv}${run reconcileApp}${reconcileFlags}";
  # Concatenate onto a devshell `commands` list (`++ devshellSkills.commands`).
  # Every entry is fully repo-agnostic — they only reference `dir`/`scope`,
  # which this hook already owns — so every consuming repo shares them verbatim.
  commands = [
    {
      category = "skills";
      name = "reap-skills";
      # The detached form (`nix run "$PRJ_ROOT#purge"`) needs no dev shell and
      # clears EVERY managed skill in the scope, strays included — surfaced here
      # so users know a more thorough removal exists.
      help = ''Remove every skill this dev shell installed (one owner; args pass through, -y/--yes skips the prompt and is needed without a TTY); for a detached, thorough purge of ALL managed skills run: nix run "$PRJ_ROOT#${removeApp}" -- --scope=${scope}'';
      command = ''
        ${findRoot}
        ${runHereWithArgs removeApp}
      '';
    }
    {
      # What entering the dev shell does, without entering it again: an agent
      # already running inside it picks up a changed skill set this way.
      category = "skills";
      name = "reconcile-skills";
      help = "Install, update and sweep this dev shell's skills, as entering it does; args pass through to ${reconcileApp}";
      command = ''
        ${findRoot}
        ${updateEnv}${runHere reconcileApp}${reconcileFlags} "$@"
      '';
    }
    {
      category = "skills";
      name = "update-skills-devshell";
      help = "Bump the ${dir}/ sub-flake lock (the skill set), then reconcile the skills";
      command = ''
        ${findRoot}
        nix flake update --flake "$root/${dir}" "$@" && ${updateEnv}${runHere reconcileApp}${reconcileFlags}
      '';
    }
  ];
  # The repo-agnostic ci/dev/maintenance trio every consumer otherwise
  # re-hand-rolls inline. They carry zero repo-specific data, so they live
  # here too (`standardCommands ++ devshellSkills.commands`) rather than
  # drifting copy-by-copy across repos.
  standardCommands = [
    {
      category = "ci";
      name = "check";
      help = "Run the full test suite via nix flake check";
      command = ''nix flake check "$@"'';
    }
    {
      category = "dev";
      name = "fmt";
      help = "Format the tree with treefmt (nixfmt + shfmt)";
      command = ''nix fmt "$@"'';
    }
    {
      category = "maintenance";
      name = "update-flake";
      help = "Update all flake inputs and rewrite flake.lock";
      command = ''nix flake update "$@"'';
    }
  ];
}
