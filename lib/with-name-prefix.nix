# Consumer-side wrapper that re-prefixes a pre-built skill (or skills
# env) without requiring access to the upstream source tree. Two
# scenarios it covers:
#
#   • Skill-pack author shipping multiple namespaced variants of the
#     same pack from a single flake.
#   • Downstream consumer pulling a pack from an upstream flake and
#     namespacing it under their own prefix to avoid collisions with
#     other vendored packs in `~/.claude/skills/`.
#
# Behavior: produces a new derivation with the same on-disk contents as
# the input but moved to `share/claude-skills/<prefix>-<oldName>/`. The
# `SKILL.md` frontmatter `name:` and the `.flake-skills-managed.json`
# sentinel `skillName` are rewritten to the prefixed name; everything
# else in the sentinel (managedBy*, originalSkillName, version, ...)
# is preserved verbatim so traceability back to the upstream lineage
# survives. Passthru is refreshed so the wrapped drv behaves like a
# first-class `mkSkill` output to the rest of the library (home-manager
# activation, installer, reconcile, mkSkillsEnv).
#
# A `-` separator is auto-inserted between prefix and old name, matching
# the rest of the library's `packagePrefix` defaults. Chaining wrappers
# is fine: `withNamePrefix "a" (withNamePrefix "b" s)` ⇒ `a-b-<orig>`.
#
# Usage (single skill):
#
#   flake-skills.lib.withNamePrefix {
#     pkgs       = nixpkgs.legacyPackages.${system};
#     namePrefix = "gstack";
#     skill      = skillspkgs.packages.${system}.skill-foo;
#   }
#   # → drv with passthru.flakeSkillName = "gstack-foo"
#
# Usage (skills env from mkAllSkillsFlake / mkSkillsEnv):
#
#   flake-skills.lib.withNamePrefix {
#     pkgs       = nixpkgs.legacyPackages.${system};
#     namePrefix = "superpowers";
#     skill      = skillspkgs.packages.${system}.default;
#   }
#   # → env whose flakeSkillsEnv members are individually prefix-wrapped
{ }:
{
  # Nixpkgs instance for the target system. Used for stdenvNoCC + jq +
  # symlinkJoin. Same shape as mkSkillsEnv's `pkgs`.
  pkgs,
  # Prefix string. Required; non-empty. Validated against
  # `^[a-z0-9][a-z0-9-]*$` so the combined `<prefix>-<oldName>` can
  # still satisfy Claude Code's `^[a-z0-9-]{1,64}$` name constraint
  # (the combined length is asserted per-skill in `wrapOne`). An
  # auto-inserted `-` separator joins prefix and old name.
  namePrefix,
  # Either a single skill drv (carrying `passthru.isFlakeSkill`) or a
  # skills env drv (carrying `passthru.isFlakeSkillsEnv`). Anything
  # else throws — keeps the helper honest about what it can re-wrap.
  skill,
}:
let
  inherit (pkgs) lib;

  validPrefix =
    let
      ok = builtins.match "[a-z0-9][a-z0-9-]*" namePrefix != null;
    in
    if !ok then
      throw (
        "flake-skills.lib.withNamePrefix: namePrefix "
        + builtins.toJSON namePrefix
        + " is invalid. Must be a non-empty string matching "
        + "^[a-z0-9][a-z0-9-]*$ (start with a lowercase letter or "
        + "digit, then any of [a-z0-9-])."
      )
    else
      namePrefix;

  # Wrap a single skill: copy contents under the new directory name,
  # rewrite frontmatter + sentinel, refresh passthru.
  wrapOne =
    drv:
    let
      oldName = drv.passthru.flakeSkillName or (throw ''
        flake-skills.lib.withNamePrefix: input drv must be a flake-skills
        skill (carrying `passthru.flakeSkillName`). Got a derivation
        without that attribute.
      '');
      newName = "${validPrefix}-${oldName}";
      nameOk = builtins.match "[a-z0-9-]{1,64}" newName != null;
    in
    assert lib.assertMsg nameOk (
      "flake-skills.lib.withNamePrefix: combined name "
      + builtins.toJSON newName
      + " violates Claude Code's name rule ^[a-z0-9-]{1,64}$ "
      + "(lowercase letters, digits, hyphens; ≤64 chars). "
      + "Use a shorter `namePrefix`."
    );
    pkgs.stdenvNoCC.mkDerivation {
      pname = "claude-skill-${newName}";
      version = drv.version or "0.1.0";
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.jq ];
      passthru = {
        isFlakeSkill = true;
        flakeSkillName = newName;
      };
      installPhase = ''
        runHook preInstall
        srcDir=${drv}/share/claude-skills/${oldName}
        dstDir=$out/share/claude-skills/${newName}
        mkdir -p "$dstDir"
        cp -rL --no-preserve=mode,ownership "$srcDir/." "$dstDir/"
        chmod -R u+w "$dstDir"

        # Rewrite SKILL.md frontmatter `name:` only. Same fenced-block
        # contract as `mkSkill`'s normalize pass: only the first
        # `---`-delimited block is touched, only a column-0 `name:` key.
        awk -v newname=${lib.escapeShellArg newName} '
          BEGIN { state = 0; seen = 0 }
          NR == 1 && $0 != "---" {
            print "---"; print "name: " newname; print "---"; print ""
            print; state = 2; next
          }
          NR == 1 { print; state = 1; next }
          state == 1 && $0 == "---" {
            if (seen == 0) print "name: " newname
            print; state = 2; next
          }
          state == 1 && /^name[[:blank:]]*:/ {
            print "name: " newname; seen = 1; next
          }
          { print }
        ' "$dstDir/SKILL.md" > "$dstDir/SKILL.md.tmp"
        mv "$dstDir/SKILL.md.tmp" "$dstDir/SKILL.md"
        chmod 644 "$dstDir/SKILL.md"

        # Sentinel: rewrite `skillName`, leave everything else verbatim
        # so `originalSkillName`, `managedBy*`, and `version` still
        # trace back to the original lineage. mkSkill guarantees the
        # file exists, but the `-f` guard keeps us robust if the input
        # was hand-built without one.
        if [ -f "$dstDir/.flake-skills-managed.json" ]; then
          jq --arg n ${lib.escapeShellArg newName} \
             '.skillName = $n' \
             "$dstDir/.flake-skills-managed.json" \
             > "$dstDir/.flake-skills-managed.json.tmp"
          mv "$dstDir/.flake-skills-managed.json.tmp" \
             "$dstDir/.flake-skills-managed.json"
          chmod 644 "$dstDir/.flake-skills-managed.json"
        fi
        runHook postInstall
      '';
      meta = drv.meta or { };
    };

  isEnv = (skill.passthru.isFlakeSkillsEnv or false);
  isSkill = (skill.passthru.isFlakeSkill or false);
in
if isEnv then
  let
    members = skill.passthru.flakeSkillsEnv;
    wrapped = map (m: {
      name = "${validPrefix}-${m.name}";
      drv = wrapOne m.drv;
    }) members;
  in
  pkgs.symlinkJoin {
    name = "${validPrefix}-${skill.name or "claude-skills-env"}";
    paths = map (m: m.drv) wrapped;
    passthru = {
      isFlakeSkillsEnv = true;
      flakeSkillsEnv = wrapped;
    };
  }
else if isSkill then
  wrapOne skill
else
  throw ''
    flake-skills.lib.withNamePrefix: `skill` must be a derivation
    produced by flake-skills' `mkSkillFlake` / `mkAllSkillsFlake` /
    `mkSkillsEnv` (carrying `passthru.isFlakeSkill` or
    `passthru.isFlakeSkillsEnv`). Got a derivation with neither.
  ''
