# Skill-name / prefix validators. Lib-only (no nixpkgs / pkgs) so both
# the build-side `internal.nix` (which has `nixpkgs.lib`) and the
# consumer-side `with-name-prefix.nix` (which only has `pkgs.lib`) can
# import it — keeping the name rules defined in exactly one place.
{ lib }:
{
  # Claude Code's hard constraint on a skill's effective name (the `name:`
  # frontmatter / install directory): lowercase letters, digits, hyphens,
  # ≤64 chars. `builtins.match` is whole-string-anchored.
  isValidSkillName = name: builtins.match "[a-z0-9-]{1,64}" name != null;

  # Assert a name is valid at eval, so a bad `skillName` / `renameFn` /
  # combined prefix fails `nix flake check` with a clear message instead
  # of silently producing a skill Claude Code refuses to load. `what`
  # names the offending value in the message (e.g. "skill name").
  assertValidSkillName =
    name: what:
    lib.assertMsg (builtins.match "[a-z0-9-]{1,64}" name != null) (
      "agent-skill-flake: ${what} ${builtins.toJSON name} is invalid. "
      + "Claude Code skill names must match ^[a-z0-9-]{1,64}$ "
      + "(lowercase letters, digits, hyphens; ≤64 chars)."
    );

  # A `withNamePrefix` prefix must start with a lowercase letter or digit,
  # then any of [a-z0-9-], so the joined `<prefix>-<oldName>` can still
  # satisfy the skill-name rule (combined length asserted per-skill).
  # Returns the prefix unchanged, or throws.
  validateNamePrefix =
    namePrefix:
    if builtins.match "[a-z0-9][a-z0-9-]*" namePrefix != null then
      namePrefix
    else
      throw (
        "agent-skill-flake.lib.withNamePrefix: namePrefix "
        + builtins.toJSON namePrefix
        + " is invalid. Must be a non-empty string matching "
        + "^[a-z0-9][a-z0-9-]*$ (start with a lowercase letter or "
        + "digit, then any of [a-z0-9-])."
      );

  # The owner segment spliced into a package key (`<packagePrefix><segment>-<name>`).
  # `""` is allowed and means "no segment" (a deliberate opt-out); a non-empty
  # segment obeys the same rule as a name prefix so the composed key stays a
  # valid attribute name. Returns the segment unchanged, or throws.
  validateNamespaceSegment =
    segment:
    if segment == "" || builtins.match "[a-z0-9][a-z0-9-]*" segment != null then
      segment
    else
      throw (
        "agent-skill-flake: namespace segment "
        + builtins.toJSON segment
        + " is invalid. Must be \"\" (no namespace) or match "
        + "^[a-z0-9][a-z0-9-]*$ (start with a lowercase letter or "
        + "digit, then any of [a-z0-9-])."
      );

  # Guard an install set against two distinct skills resolving to the same
  # Claude install name (which would clobber each other at
  # ~/.claude/skills/<name>). Records are `[ { name; drv; } ]` where `name`
  # is the install identity. Identical drvs under one name are deduped
  # (harmless); distinct drvs sharing a name throw with a fix suggestion.
  # Returns the records unchanged when there is no collision.
  assertUniqueSkillNames =
    { label, skills }:
    let
      byName = lib.groupBy (s: s.name) skills;
      clashes = lib.filterAttrs (_: ss: lib.length (lib.unique (map (s: s.drv.outPath) ss)) > 1) byName;
      names = builtins.attrNames clashes;
    in
    if names == [ ] then
      skills
    else
      throw ''
        agent-skill-flake: ${label} bundles multiple distinct skills that install under the same name:
          ${lib.concatStringsSep "\n  " names}
        Claude installs every skill at ~/.claude/skills/<name>, so these would clobber each other.
        Give the colliding skills distinct install names — e.g. prefix one by its owner via a
        per-source `prefix` (combinations) or a `renameFn`.
      '';
}
