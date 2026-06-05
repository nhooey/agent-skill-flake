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
  # The example sources are local dirs with no hosting owner, so most
  # fixtures opt out of the owner namespace (`namespaceFn = _: ""`) and
  # their package keys are the bare `agent-skill-<name>` / `agent-skills-all`.
  # Fixtures that exercise owner namespacing call `flakeLib` directly and
  # pass a `source`. These wrappers also bake in `nixpkgs`.
  mkSkill =
    args:
    flakeLib.mkSkillFlake (
      {
        inherit nixpkgs;
        namespaceFn = _: "";
      }
      // args
    );
  mkAll =
    args:
    flakeLib.mkAllSkillsFlake (
      {
        inherit nixpkgs;
        namespaceFn = _: "";
      }
      // args
    );
  mkAgg =
    args:
    flakeLib.mkAggregateSkillsFlake (
      {
        inherit nixpkgs;
        namespaceFn = _: "";
      }
      // args
    );
  # mkCombination has no local base, so no namespaceFn — its sources arrive
  # already keyed by their own builds.
  mkCombo = args: flakeLib.mkCombination ({ inherit nixpkgs; } // args);

  # Shared source + name for the four `extraFiles` variants below: the same
  # skill rebuilt with different `extraFiles` settings so the bats tests can
  # assert positive, negative, no-match, and directory-skip behaviour
  # without paying for four distinct source trees.
  extraFilesSrc = ./example-skill-extra-files;
  extraFilesSkillName = "example-skill-extra-files";

  # A combination over a prefixed source: `gamma` under prefix "cx" → key
  # `agent-skill-cx-gamma`, env member `cx-gamma`. In the `let` so
  # `fixtureCombinationReused` can feed it back in as a source.
  fixtureCombination = mkCombo {
    name = "combo";
    envName = "agent-skills-combo";
    sources = [
      {
        source = mkAll {
          skillsDir = ./example-source-dir;
          name = "combo-src";
        };
        prefix = "cx";
      }
    ];
  };
in
{
  inherit fixtureCombination;

  # Single-skill fixture.
  fixture = mkSkill {
    skillName = "example-skill";
    src = ./example-skill;
  };

  # Multi-skill fixture: directory containing alpha/ + beta/ (and a
  # not-a-skill/ subdir + a top-level README.md to exercise discovery
  # filtering).
  fixtureAll = mkAll {
    skillsDir = ./example-skills-dir;
    name = "example-skills-dir";
  };

  # Owner-namespaced fixture: `source = { owner = "acme"; }` with the default
  # `namespaceFn` (reads `ctx.source.owner`). Per-skill keys become
  # `agent-skill-acme-{alpha,beta}` and the aggregate `agent-skills-acme-all`,
  # while the installed identities stay bare (`alpha`, `beta`).
  fixtureAllOwner = flakeLib.mkAllSkillsFlake {
    inherit nixpkgs;
    skillsDir = ./example-skills-dir;
    source = {
      owner = "acme";
    };
  };

  # Single-skill fixture whose SKILL.md frontmatter `name:` diverges from
  # `skillName` — exercises build-time frontmatter normalization.
  fixtureRename = mkSkill {
    skillName = "example-skill-renamed";
    src = ./example-skill-rename;
  };

  fixtureExtraFiles = mkSkill {
    skillName = extraFilesSkillName;
    src = extraFilesSrc;
    extraFiles = [
      "*.md"
      "*.sh"
      "*.dot"
    ];
  };
  fixtureExtraFilesOff = mkSkill {
    skillName = extraFilesSkillName;
    src = extraFilesSrc;
  };
  fixtureExtraFilesNoMatch = mkSkill {
    skillName = extraFilesSkillName;
    src = extraFilesSrc;
    extraFiles = [ "*.nonexistent" ];
  };
  # `extraFiles = [ "*" ]` against a source that has a top-level directory
  # (`companion-dir/`) which is NOT in `extraDirs`. The `[ -f ]` guard
  # inside the install loop must skip the directory so only top-level
  # regular files are shipped.
  fixtureExtraFilesDirSkip = mkSkill {
    skillName = extraFilesSkillName;
    src = extraFilesSrc;
    extraFiles = [ "*" ];
  };

  # Single-skill fixture built with `agent = "codex"` so the install scope
  # tests can assert the codex profile's `.codex/skills/` suffix is used
  # (instead of `.claude/skills/`).
  fixtureCodex = mkSkill {
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
  # so alpha → "nhooey-alpha-0123456-20240424". The owner namespace is
  # opted out (wrapper `namespaceFn = _: ""`) so the package key is the
  # bare `agent-skill-<renamed>`.
  fixtureAllRenamed = mkAll {
    skillsDir = ./example-skills-dir;
    name = "renamed-all";
    source = {
      owner = "nhooey";
      repo = "nix-skills";
      rev = "0123456789abcdef0123456789abcdef01234567";
      # Nix hands this to consumers as `self.lastModifiedDate`
      # ("%Y%m%d%H%M%S", UTC); we just slice it.
      lastModifiedDate = "20240424120000";
      narHash = "sha256-deadbeef";
    };
    renameFn =
      ctx: "${ctx.source.owner}-${ctx.name}-${ctx.source.shortRev}-${ctx.source.lastModifiedCompact}";
  };

  # ── Aggregate reconcile (declarative dev-shell convergence) ──────────
  # The combined reconcile converges a target to exactly the union of all
  # aggregated skills. These fixtures exercise convergence (a shrinking
  # union sweeps the dropped skill), idempotence, and coexistence (two
  # aggregates sharing one target, each owning only its own slice).

  # Full union: base example-skills-dir (alpha, beta) + a prefixed source
  # (example-source-dir's gamma → src-gamma). appName "converge".
  fixtureAggConvergeFull = mkAgg {
    skillsDir = ./example-skills-dir;
    name = "converge";
    sources = [
      {
        source = mkAll {
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
  # the git-skills stray-leftover bug.
  fixtureAggConvergeReduced = mkAgg {
    skillsDir = ./example-skills-dir;
    name = "converge";
    sources = [ ];
  };

  # Coexistence: two aggregates with distinct appNames installing into one
  # target. `aggCoexistA` owns alpha+beta (appName "coexist-a"); `aggCoexistB`
  # owns gamma (appName "coexist-b", verbatim source, no local base). Each
  # reconcile must sweep only its own strays and never the other's skills.
  fixtureAggCoexistA = mkAgg {
    skillsDir = ./example-skills-dir;
    name = "coexist-a";
    sources = [ ];
  };
  fixtureAggCoexistB = mkAgg {
    name = "coexist-b";
    sources = [
      {
        source = mkAll {
          skillsDir = ./example-source-dir;
          name = "coexist-b-src";
        };
      }
    ];
  };

  # ── Aggregate cherry-pick (per-source `skills` filter) ───────────────
  # A source exposing two skills (example-skills-dir's alpha + beta) with
  # only `alpha` cherry-picked. Proves the per-source `skills` filter keeps
  # the named skill and drops its sibling — the field the reconcile rewrite
  # silently ignored. Two variants cover both arms of `recordsForSource`:
  # the verbatim merge and the re-prefixed merge.
  fixtureAggCherryPick = mkAgg {
    name = "cherrypick";
    sources = [
      {
        source = mkAll {
          skillsDir = ./example-skills-dir;
          name = "cherrypick-src";
        };
        skills = [ "alpha" ];
      }
    ];
  };
  fixtureAggCherryPickPrefixed = mkAgg {
    name = "cherrypick-px";
    sources = [
      {
        source = mkAll {
          skillsDir = ./example-skills-dir;
          name = "cherrypick-px-src";
        };
        prefix = "px";
        # Cherry-pick matches the *upstream* name (`alpha`), even though the
        # installed skill lands re-prefixed as `px-alpha`.
        skills = [ "alpha" ];
      }
    ];
  };

  # ── Combination (mkCombination) ──────────────────────────────────────
  # Regression guard for the dropped-`packages` smell: feed the combination
  # back in as a source — the re-aggregated set must contain its prefixed
  # key (`agent-skill-cx-gamma`). (`fixtureCombination` is in the `let` above.)
  fixtureCombinationReused = mkAgg {
    name = "combo-reused";
    sources = [ { source = fixtureCombination; } ];
  };

  # Two sources expose a skill that installs under the same name (`alpha`:
  # example-skills-dir's alpha vs example-skill's, different content), with
  # the second re-prefixed to `bx`. The per-source `prefix` resolves what
  # would otherwise be a duplicate-install-name collision, so the union
  # builds with `agent-skill-alpha`, `agent-skill-beta`, `agent-skill-bx-alpha`.
  fixtureCombinationPrefixResolves = mkCombo {
    name = "combo-resolve";
    envName = "agent-skills-combo-resolve";
    sources = [
      {
        source = mkAll {
          skillsDir = ./example-skills-dir;
          name = "resolve-a";
        };
      }
      {
        source = mkSkill {
          skillName = "alpha";
          src = ./example-skill;
        };
        prefix = "bx";
      }
    ];
  };

  # A source that exposes a named pack env (`agent-skills-pack-mini`, just
  # `alpha`) in its `packages`. A combination selects it via `pack`, so the
  # cherry-pick comes from the bundle's membership; `prefix = "fp"` brands it.
  # The union must contain `agent-skill-fp-alpha` and not `…-beta`.
  fixtureCombinationFromPack =
    let
      base = mkAll {
        skillsDir = ./example-skills-dir;
        name = "from-pack-src";
      };
      packSource = base // {
        packages = nixpkgs.lib.mapAttrs (
          system: pkgs:
          pkgs
          // {
            agent-skills-pack-mini = flakeLib.mkSkillsEnv {
              pkgs = nixpkgs.legacyPackages.${system};
              name = "agent-skills-pack-mini";
              skills = [ base.bySkillName.${system}.alpha ];
            };
          }
        ) base.packages;
      };
    in
    mkCombo {
      name = "from-pack";
      envName = "agent-skills-from-pack";
      sources = [
        {
          source = packSource;
          pack = "agent-skills-pack-mini";
          prefix = "fp";
        }
      ];
    };
}
