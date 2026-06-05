# Root-side wiring for a `skills-devshell/` sub-flake invoked at runtime.
# Returns the two shell snippets a repo's ROOT devShell splices in, so the
# `nix run "$PRJ_ROOT/<dir>#<app>"` strings live in one place instead of being
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
  # Splice into a devshell `commands` entry's `command` (remove the whole set).
  reap = run removeApp;
}
