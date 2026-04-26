# `self` is this flake's own source — needed so callers don't have to
# pass through provenance (rev, dirty flag) to mkSkill manually.
{ self }:
let
  # Hardcoded canonical URL for this lineage. Forks should rewrite this
  # (run `nix run .#init` to do so automatically based on `git remote`).
  upstreamUrl = "github:nhooey/flake-skills";

  # `self.dirtyRev` looks like "<sha>-dirty"; strip so `rev` is always a
  # clean SHA. The dirty flag lives in its own field.
  stripDirtySuffix =
    s:
    let
      n = builtins.stringLength s;
      slen = builtins.stringLength "-dirty";
    in
    if n >= slen && builtins.substring (n - slen) slen s == "-dirty" then
      builtins.substring 0 (n - slen) s
    else
      s;

  # Per-build provenance baked into every skill derivation's sentinel.
  # - `rev`: parent commit, clean SHA whether the build was clean or dirty.
  # - `dirty`: quick boolean check; consumers can short-circuit on `false`.
  # - `narHash`: content hash of the source as Nix sees it. Differentiates
  #   two dirty builds on the same parent commit (different uncommitted
  #   changes → different narHash). Always present, clean or dirty.
  provenance = {
    inherit upstreamUrl;
    rev = stripDirtySuffix (self.rev or self.dirtyRev or "unknown");
    dirty = !(self ? rev);
    narHash = self.narHash or "unknown";
  };
in
{
  inherit upstreamUrl provenance;

  mkSkillFlake = args:
    import ./mk-skill-flake.nix (args // { inherit provenance; });

  mkAllSkillsFlake = args:
    import ./mk-all-skills-flake.nix (args // { inherit provenance; });
}
