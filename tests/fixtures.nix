# Test fixtures: skill flakes built from the `tests/example-*` sources via
# the library's own builders. Kept out of flake.nix so the top-level
# outputs stay structural (same rationale as checks.nix), and imported
# directly by checks.nix so adding a fixture touches one file, not three.
#
# `flakeLib` is this flake's `lib` (so fixtures exercise the real builders
# with provenance baked in); `nixpkgs` is the flake's nixpkgs input. Both
# are system-independent — each fixture is a flake-like attrset whose
# packages/apps are themselves per-system.
{
  flakeLib,
  nixpkgs,
}:
let
  # Shared source + name for the four `extraFiles` variants below: the same
  # skill rebuilt with different `extraFiles` settings so the bats tests can
  # assert positive, negative, no-match, and directory-skip behaviour
  # without paying for four distinct source trees.
  extraFilesSrc = ./example-skill-extra-files;
  extraFilesSkillName = "example-skill-extra-files";
in
{
  # Single-skill fixture.
  fixture = flakeLib.mkSkillFlake {
    inherit nixpkgs;
    skillName = "example-skill";
    src = ./example-skill;
  };

  # Multi-skill fixture: directory containing alpha/ + beta/ (and a
  # not-a-skill/ subdir + a top-level README.md to exercise discovery
  # filtering).
  fixtureAll = flakeLib.mkAllSkillsFlake {
    inherit nixpkgs;
    skillsDir = ./example-skills-dir;
    name = "example-skills-dir";
  };

  # Single-skill fixture whose SKILL.md frontmatter `name:` diverges from
  # `skillName` — exercises build-time frontmatter normalization.
  fixtureRename = flakeLib.mkSkillFlake {
    inherit nixpkgs;
    skillName = "example-skill-renamed";
    src = ./example-skill-rename;
  };

  fixtureExtraFiles = flakeLib.mkSkillFlake {
    inherit nixpkgs;
    skillName = extraFilesSkillName;
    src = extraFilesSrc;
    extraFiles = [ "*.md" "*.sh" "*.dot" ];
  };
  fixtureExtraFilesOff = flakeLib.mkSkillFlake {
    inherit nixpkgs;
    skillName = extraFilesSkillName;
    src = extraFilesSrc;
  };
  fixtureExtraFilesNoMatch = flakeLib.mkSkillFlake {
    inherit nixpkgs;
    skillName = extraFilesSkillName;
    src = extraFilesSrc;
    extraFiles = [ "*.nonexistent" ];
  };
  # `extraFiles = [ "*" ]` against a source that has a top-level directory
  # (`companion-dir/`) which is NOT in `extraDirs`. The `[ -f ]` guard
  # inside the install loop must skip the directory so only top-level
  # regular files are shipped.
  fixtureExtraFilesDirSkip = flakeLib.mkSkillFlake {
    inherit nixpkgs;
    skillName = extraFilesSkillName;
    src = extraFilesSrc;
    extraFiles = [ "*" ];
  };

  # Single-skill fixture built with `agent = "codex"` so the install scope
  # tests can assert the codex profile's `.codex/skills/` suffix is used
  # (instead of `.claude/skills/`).
  fixtureCodex = flakeLib.mkSkillFlake {
    inherit nixpkgs;
    skillName = "example-skill";
    src = ./example-skill;
    agent = "codex";
  };

  # Multi-skill fixture exercising a rich `renameFn`: the derived name
  # encodes the source owner, original skill name, short git rev, and git
  # last-modified date. `source` uses fixed values so the names are
  # deterministic under `nix flake check`:
  #   lastModifiedDate "20240424120000" → compact "20240424"
  #   rev[:7]                            → "0123456"
  # so alpha → "nhooey-alpha-0123456-20240424".
  fixtureAllRenamed = flakeLib.mkAllSkillsFlake {
    inherit nixpkgs;
    skillsDir = ./example-skills-dir;
    name = "renamed-all";
    source = {
      owner = "nhooey";
      repo = "skills-nix";
      rev = "0123456789abcdef0123456789abcdef01234567";
      # Nix hands this to consumers as `self.lastModifiedDate`
      # ("%Y%m%d%H%M%S", UTC); we just slice it.
      lastModifiedDate = "20240424120000";
      narHash = "sha256-deadbeef";
    };
    renameFn =
      ctx:
      "${ctx.source.owner}-${ctx.name}-${ctx.source.shortRev}-${ctx.source.lastModifiedCompact}";
  };

  # ── Aggregate reconcile (declarative dev-shell convergence) ──────────
  # The combined reconcile converges a target to exactly the union of all
  # aggregated skills. These fixtures exercise convergence (a shrinking
  # union sweeps the dropped skill), idempotence, and coexistence (two
  # aggregates sharing one target, each owning only its own slice).

  # Full union: base example-skills-dir (alpha, beta) + a prefixed source
  # (example-source-dir's gamma → src-gamma). appName "converge".
  fixtureAggConvergeFull = flakeLib.mkAggregateSkillsFlake {
    inherit nixpkgs;
    skillsDir = ./example-skills-dir;
    name = "converge";
    sources = [
      {
        source = flakeLib.mkAllSkillsFlake {
          inherit nixpkgs;
          skillsDir = ./example-source-dir;
          name = "converge-src";
        };
        prefix = "src";
      }
    ];
  };

  # Same appName "converge", source dropped — the union shrinks to base
  # (alpha, beta) only, so reconciling with it must sweep the now-stray
  # src-gamma left by the full reconcile. This is the regression test for
  # the skills-git stray-leftover bug.
  fixtureAggConvergeReduced = flakeLib.mkAggregateSkillsFlake {
    inherit nixpkgs;
    skillsDir = ./example-skills-dir;
    name = "converge";
    sources = [ ];
  };

  # Coexistence: two aggregates with distinct appNames installing into one
  # target. `aggCoexistA` owns alpha+beta (appName "coexist-a"); `aggCoexistB`
  # owns gamma (appName "coexist-b", verbatim source, no local base). Each
  # reconcile must sweep only its own strays and never the other's skills.
  fixtureAggCoexistA = flakeLib.mkAggregateSkillsFlake {
    inherit nixpkgs;
    skillsDir = ./example-skills-dir;
    name = "coexist-a";
    sources = [ ];
  };
  fixtureAggCoexistB = flakeLib.mkAggregateSkillsFlake {
    inherit nixpkgs;
    name = "coexist-b";
    sources = [
      {
        source = flakeLib.mkAllSkillsFlake {
          inherit nixpkgs;
          skillsDir = ./example-source-dir;
          name = "coexist-b-src";
        };
      }
    ];
  };
}
