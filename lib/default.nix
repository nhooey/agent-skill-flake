# `self` is this flake's own source — needed so callers don't have to
# pass through provenance (rev, dirty flag) to mkSkill manually.
{ self }:
let
  # `lib` via this flake's own nixpkgs input, so default.nix keeps its
  # `{ self }` signature (no nixpkgs threaded from callers) yet can use
  # pure helpers like `lib.removeSuffix`.
  inherit (self.inputs.nixpkgs) lib;

  # Hardcoded canonical URL for this lineage. Forks should rewrite this
  # (run `nix run .#init` to do so automatically based on `git remote`).
  upstreamUrl = "github:nhooey/flake-skills";

  # Per-build provenance baked into every skill derivation's sentinel.
  # - `rev`: parent commit, clean SHA whether the build was clean or dirty.
  #   `self.dirtyRev` looks like "<sha>-dirty"; `removeSuffix` strips it so
  #   `rev` is always a clean SHA (the dirty flag lives in its own field).
  # - `dirty`: quick boolean check; consumers can short-circuit on `false`.
  # - `narHash`: content hash of the source as Nix sees it. Differentiates
  #   two dirty builds on the same parent commit (different uncommitted
  #   changes → different narHash). Always present, clean or dirty.
  provenance = {
    inherit upstreamUrl;
    rev = lib.removeSuffix "-dirty" (self.rev or self.dirtyRev or "unknown");
    dirty = !(self ? rev);
    narHash = self.narHash or "unknown";
  };

  # Marketplace / aggregation helpers. Defined in their own module so
  # mk-aggregate-skills-flake.nix can reuse them without importing through
  # this file (which takes `self`, so re-entering it would be circular).
  marketplace = import ./marketplace.nix { };
in
{
  inherit upstreamUrl provenance;

  mkSkillFlake = args: import ./mk-skill-flake.nix (args // { inherit provenance; });

  mkAllSkillsFlake = args: import ./mk-all-skills-flake.nix (args // { inherit provenance; });

  # Multi-skill env (the `pkgs.buildEnv` analogue for skills). Takes
  # already-built skill drvs — no provenance threading needed because
  # each member carries its own.
  mkSkillsEnv = import ./mk-skills-env.nix { };

  # Consumer-side prefix wrapper. Takes a pre-built skill or skills env
  # and emits a renamed copy under `<namePrefix>-<oldName>/`, refreshing
  # frontmatter, sentinel, and passthru. No provenance threading — the
  # input already carries its lineage in the sentinel, and the wrapper
  # leaves those fields alone.
  withNamePrefix = import ./with-name-prefix.nix { };

  # ── Marketplace / aggregation surface ────────────────────────────────
  # Convenience functions for flakes that aggregate several upstream skill
  # flakes (the "marketplace" consumer). These replace hand-rolled logic
  # that used to reach into the private `internal.nix` module.
  inherit (marketplace)
    # Installer over an arbitrary already-built `[ { name; drv; } ]` set —
    # the primitive that used to force the internal.nix import.
    mkInstaller
    # The plural of withNamePrefix: prefix-wrap every skill in a source.
    withNamePrefixSource
    # withNamePrefixSource + mkInstaller: installer over a prefixed source.
    mkPrefixedInstaller
    # The `"<bin> <args>"` install string for one source.
    installCommandFor
    # Profile resolver + raw profile data, for callers that need them.
    resolveAgentProfile
    agentProfiles
    ;

  # The whole marketplace in one call: merge an optional local skillsDir
  # with a list of (optionally prefixed) upstream source flakes into one
  # package set + apps + a devshell-ready install script.
  mkAggregateSkillsFlake =
    args: import ./mk-aggregate-skills-flake.nix (args // { inherit provenance; });
}
