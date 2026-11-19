# shellcheck shell=bash
# shellcheck disable=SC2034 # read by scope.bash and the app's own script
#
# The prelude every app built by mkShellApp, and the agent-skill-flake
# command, sources first (lib/internal.nix `scopePrelude`), after
# `pkgs.replaceVars` fills each placeholder below. It sets `app_name`,
# `personal_suffix` and `project_suffix` and sources scope.bash, so
# `parse_scope_args` is available to the app's own script.
app_name="@appName@"
personal_suffix='@personalSuffix@'
project_suffix='@projectSuffix@'

# shellcheck source=/dev/null # a store path
source @scopeBash@
