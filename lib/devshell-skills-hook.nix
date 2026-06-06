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
}:
let
  run = app: ''nix run "$PRJ_ROOT/${dir}#${app}" -- --scope=${scope}'';
in
{
  # Splice into `devshell.startup.<name>.text` (reconcile on `nix develop`).
  startup = run reconcileApp;
  # Concatenate onto a devshell `commands` list (`++ devshellSkills.commands`).
  # Both entries are fully repo-agnostic — they only reference `dir`/`scope`,
  # which this hook already owns — so every consuming repo shares them verbatim.
  commands = [
    {
      category = "skills";
      name = "reap-skills";
      # The detached form (`nix run "$PRJ_ROOT#purge"`) needs no dev shell and
      # clears EVERY managed skill in the scope, strays included — surfaced here
      # so users know a more thorough removal exists.
      help = ''Remove every skill this dev shell installed (one owner); for a detached, thorough purge of ALL managed skills run: nix run "$PRJ_ROOT#${removeApp}" -- --scope=${scope}'';
      command = run removeApp;
    }
    {
      category = "skills";
      name = "update-skills-devshell";
      help = "Bump the ${dir}/ sub-flake lock (the skill set)";
      command = ''nix flake update --flake "$PRJ_ROOT/${dir}" "$@"'';
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
