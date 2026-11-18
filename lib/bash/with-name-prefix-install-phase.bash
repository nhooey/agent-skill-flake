# shellcheck shell=bash
# shellcheck disable=SC2154 # out is set by stdenv
#
# withNamePrefix's installPhase (lib/with-name-prefix.nix), sourced from
# it after `pkgs.replaceVars` fills each placeholder below with a value
# escaped by `lib.escapeShellArg`:
#
#   srcDir                  the input skill's installed directory
#   newName                 the prefixed name
#   normalizeFrontmatterAwk lib/normalize-frontmatter.nix, as a file
runHook preInstall
srcDir=@srcDir@
new_name=@newName@
normalize_frontmatter_awk=@normalizeFrontmatterAwk@
dstDir=$out/share/claude-skills/$new_name
mkdir -p "$dstDir"
cp -rL --no-preserve=mode,ownership "$srcDir/." "$dstDir/"
chmod -R u+w "$dstDir"

# Rewrite SKILL.md frontmatter `name:` via the shared normalize
# pass (lib/normalize-frontmatter.nix) — the same script mkSkill
# uses, so the fenced-block contract stays defined in one place.
awk -v newname="$new_name" \
  -f "$normalize_frontmatter_awk" \
  "$dstDir/SKILL.md" >"$dstDir/SKILL.md.tmp"
mv "$dstDir/SKILL.md.tmp" "$dstDir/SKILL.md"
chmod 644 "$dstDir/SKILL.md"

# Sentinel: rewrite `skillName`, leave everything else verbatim
# so `originalSkillName`, `managedBy*`, and `version` still
# trace back to the original lineage. mkSkill guarantees the
# file exists, but the `-f` guard keeps us robust if the input
# was hand-built without one.
if [ -f "$dstDir/.agent-skill-flake-managed.json" ]; then
  jq --arg n "$new_name" \
    '.skillName = $n' \
    "$dstDir/.agent-skill-flake-managed.json" \
    >"$dstDir/.agent-skill-flake-managed.json.tmp"
  mv "$dstDir/.agent-skill-flake-managed.json.tmp" \
    "$dstDir/.agent-skill-flake-managed.json"
  chmod 644 "$dstDir/.agent-skill-flake-managed.json"
fi
runHook postInstall
