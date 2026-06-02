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
      "flake-skills: ${what} ${builtins.toJSON name} is invalid. "
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
        "flake-skills.lib.withNamePrefix: namePrefix "
        + builtins.toJSON namePrefix
        + " is invalid. Must be a non-empty string matching "
        + "^[a-z0-9][a-z0-9-]*$ (start with a lowercase letter or "
        + "digit, then any of [a-z0-9-])."
      );
}
