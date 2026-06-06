# Flake checks. Lifted out of flake.nix so the top-level outputs stay
# structural. Called once per system via forAllSystems.
{
  self,
  nixpkgs,
  system,
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;

  # Test fixtures (skill flakes built from tests/example-* via the real
  # builders). Imported here rather than threaded through flake.nix so the
  # top-level outputs stay structural.
  inherit
    (import ./tests/fixtures.nix {
      flakeLib = self.lib;
      inherit nixpkgs;
    })
    fixture
    fixtureAll
    fixtureAllOwner
    fixtureCodex
    fixtureRename
    fixtureAllRenamed
    fixtureExtraFiles
    fixtureExtraFilesOff
    fixtureExtraFilesNoMatch
    fixtureExtraFilesDirSkip
    fixtureAggConvergeFull
    fixtureAggConvergeReduced
    fixtureAggCoexistA
    fixtureAggCoexistB
    fixtureAggCherryPick
    fixtureAggCherryPickPrefixed
    fixtureCombination
    fixtureCombinationReused
    fixtureCombinationPrefixResolves
    fixtureCombinationFromPack
    ;

  # bats + the assertion/file/support helper libraries on BATS_LIB_PATH.
  batsWith = pkgs.bats.withLibraries (p: [
    p.bats-support
    p.bats-assert
    p.bats-file
  ]);

  # Single-skill artifacts.
  skill = fixture.packages.${system}.default;
  installApp = fixture.apps.${system}.install.program;
  previewApp = fixture.apps.${system}.preview.program;
  reapSkillApp = fixture.apps.${system}.reap.program;
  purgeSkillApp = fixture.apps.${system}.purge.program;
  uninstallSkillApp = fixture.apps.${system}.uninstall.program;

  # Multi-skill artifacts.
  allSkills = fixtureAll.packages.${system}.default;
  alphaPkg = fixtureAll.packages.${system}."agent-skill-alpha";
  betaPkg = fixtureAll.packages.${system}."agent-skill-beta";

  # Rename fixtures. `renamedSkill` proves frontmatter normalization
  # (its SKILL.md declares a divergent `name:`). `renamedAlphaPkg` proves
  # the `renameFn` formula + provenance: alpha discovered under
  # tests/example-skills-dir becomes `nhooey-alpha-0123456-20240424`.
  renamedSkill = fixtureRename.packages.${system}.default;
  renamedAlphaName = "nhooey-alpha-0123456-20240424";
  renamedAlphaPkg = fixtureAllRenamed.packages.${system}."agent-skill-${renamedAlphaName}";
  installAllApp = fixtureAll.apps.${system}.install.program;
  uninstallAllApp = fixtureAll.apps.${system}.uninstall.program;
  previewAllApp = fixtureAll.apps.${system}.preview.program;
  reapAllApp = fixtureAll.apps.${system}.reap.program;
  purgeAllApp = fixtureAll.apps.${system}.purge.program;
  reconcileAllApp = fixtureAll.apps.${system}.reconcile.program;

  # Codex-profile fixture: single-skill flake built with
  # `agent = "codex"`. Used by `install-codex-profile.bats` to assert
  # that the codex profile's `.codex/skills/` suffix is used.
  installCodexApp = fixtureCodex.apps.${system}.install.program;

  # `withNamePrefix` fixtures: consumer-side prefix wrapping over a
  # pre-built single skill and a pre-built skills env. Built here (not
  # in flake.nix) because the wrapper takes per-system `pkgs`; checks.nix
  # already has `pkgs` in scope.
  wrappedSingleName = "gstack-example-skill";
  wrappedSingle = self.lib.withNamePrefix {
    inherit pkgs;
    namePrefix = "gstack";
    skill = skill;
  };
  unwrappedAlphaBetaEnv = self.lib.mkSkillsEnv {
    inherit pkgs;
    name = "alpha-beta-env";
    skills = [
      alphaPkg
      betaPkg
    ];
  };
  wrappedEnv = self.lib.withNamePrefix {
    inherit pkgs;
    namePrefix = "superpowers";
    skill = unwrappedAlphaBetaEnv;
  };

  # ── Marketplace / aggregation artifacts ──────────────────────────────
  # Built here (not in flake.nix) for the same reason as the withNamePrefix
  # fixtures: the single-system helpers take per-system `nixpkgs`/`pkgs`,
  # and checks.nix already iterates per system with `nixpkgs` in scope.

  # `lib.mkInstaller` over an arbitrary [{name;drv;}] set (alpha + beta
  # lifted straight off fixtureAll). The primitive that used to force the
  # internal.nix import.
  arbitraryInstaller = self.lib.mkInstaller {
    inherit nixpkgs system;
    appName = "arbitrary";
    skills = [
      {
        name = "alpha";
        drv = alphaPkg;
      }
      {
        name = "beta";
        drv = betaPkg;
      }
    ];
  };
  arbitraryInstallApp = "${arbitraryInstaller}/bin/install-arbitrary";

  # `lib.withNamePrefixSource` over fixtureAll → src-alpha / src-beta.
  prefixedSourceSet = self.lib.withNamePrefixSource {
    inherit nixpkgs system;
    namePrefix = "src";
    source = fixtureAll;
  };

  # `lib.mkPrefixedInstaller` over fixtureAll (default appName
  # `agent-skills-src-all`).
  prefixedInstaller = self.lib.mkPrefixedInstaller {
    inherit nixpkgs system;
    source = fixtureAll;
    namePrefix = "src";
  };
  prefixedInstallApp = "${prefixedInstaller}/bin/install-agent-skills-src-all";

  # `lib.installCommandFor` partial application — fixes nixpkgs/system.
  installCmd = args: self.lib.installCommandFor ({ inherit nixpkgs system; } // args);
  baseInstallProgram = fixtureAll.apps.${system}.install.program;

  # A second upstream "source" flake with a distinct skill name (gamma) so
  # the aggregate merge can show a verbatim non-prefixed source contributes
  # its skill while its `default` / aggregate keys are filtered out.
  sourceGamma = self.lib.mkAllSkillsFlake {
    inherit nixpkgs;
    skillsDir = ./tests/example-source-dir;
    name = "source-gamma";
    namespaceFn = _: "";
  };

  # The whole marketplace in one call: local base (example-skills-dir) + one
  # verbatim source (gamma) + one prefixed source (fixtureAll → src-*).
  agg = self.lib.mkAggregateSkillsFlake {
    inherit nixpkgs;
    skillsDir = ./tests/example-skills-dir;
    name = "aggregate-base";
    namespaceFn = _: "";
    sources = [
      { source = sourceGamma; }
      {
        source = fixtureAll;
        prefix = "src";
      }
    ];
  };
  aggPkgs = agg.packages.${system};

  # Aggregate reconcile (declarative convergence) artifacts. The combined
  # reconcile converges the target to the union; these drive the
  # convergence, idempotence, and coexistence bats checks.
  aggConvergeFullReconcile = fixtureAggConvergeFull.apps.${system}.reconcile.program;
  aggConvergeReducedReconcile = fixtureAggConvergeReduced.apps.${system}.reconcile.program;
  aggCoexistAReconcile = fixtureAggCoexistA.apps.${system}.reconcile.program;
  aggCoexistBReconcile = fixtureAggCoexistB.apps.${system}.reconcile.program;

  # Aggregate cherry-pick (per-source `skills` filter): only the selected
  # skill installs; its sibling is dropped. Drives the cherry-pick bats
  # check across the verbatim and prefixed source arms.
  aggCherryPickReconcile = fixtureAggCherryPick.apps.${system}.reconcile.program;
  aggCherryPickPrefixedReconcile = fixtureAggCherryPickPrefixed.apps.${system}.reconcile.program;

  mockHomeManager = import ./tests/modules/mock-home-manager.nix;
  mockHomeManagerLib = import ./tests/modules/mock-home-manager-lib.nix {
    lib = nixpkgs.lib;
  };
  mockDarwinHM = import ./tests/modules/mock-darwin.nix;

  # Wraps a tests/checks/<name>.bats file as a flake check. The bats file
  # loads tests/lib/bats-helpers.bash via $BATS_HELPERS and reads its
  # inputs (store paths, app paths) from env vars passed in `env`. bats
  # gives structured TAP output and real assertion diffs on failure.
  mkBatsCheck =
    {
      name,
      env ? { },
      extraInputs ? [ ],
    }:
    pkgs.runCommand "${name}-check"
      (
        {
          nativeBuildInputs = [
            batsWith
            pkgs.coreutils
          ]
          ++ extraInputs;
          BATS_HELPERS = ./tests/lib/bats-helpers.bash;
        }
        // env
      )
      ''
        set -euo pipefail
        bats --print-output-on-failure ${./tests/checks}/${name}.bats
        touch "$out"
      '';

  # A pure-evaluation check: `cond` is asserted at eval time (so a failure
  # fails `nix flake check` with `msg`), and a trivial derivation stands
  # in as the check's build product. Used for the module-eval checks,
  # which are really Nix value/string assertions — no filesystem effects.
  mkEvalCheck =
    {
      name,
      cond,
      msg,
    }:
    assert lib.assertMsg cond msg;
    pkgs.runCommand "${name}-check" { } "touch \"$out\"";
in
{
  # ──────────────────────────────────────────────────────────────
  # Single-skill checks (mkSkillFlake).
  # ──────────────────────────────────────────────────────────────

  # Package builds.
  example-skill-builds = skill;

  # `mkSkillFlake` exposes the skill at `packages.<system>.skill-<name>`
  # by default — the `skill-` prefix prevents collision with same-named
  # entries in nixpkgs or aggregator flakes (e.g. `git`).
  example-skill-package-named = mkBatsCheck {
    name = "example-skill-package-named";
    env.SKILL_PKG_ROOT = "${
      fixture.packages.${system}."agent-skill-example-skill"
    }/share/claude-skills/example-skill";
  };

  # Layout: required files present, plumbing/hidden absent, sentinel
  # JSON present with the expected required fields.
  example-skill-layout = mkBatsCheck {
    name = "example-skill-layout";
    extraInputs = [ pkgs.jq ];
    env.SKILL_ROOT = "${skill}/share/claude-skills/example-skill";
  };

  # Install obeys CLAUDE_SKILLS_DIR; creates a symlink and a GC root
  # in the override dirs; does not write to $HOME.
  example-skill-install-env = mkBatsCheck {
    name = "example-skill-install-env";
    env.INSTALL_APP = installApp;
  };

  # Preview is read-only: HOME and target_root unchanged after run.
  example-skill-preview-readonly = mkBatsCheck {
    name = "example-skill-preview-readonly";
    extraInputs = [ pkgs.findutils ];
    env.PREVIEW_APP = previewApp;
  };

  # Single-skill flake exposes a reap app — sanity check that
  # mk-skill-flake wires it correctly. Behavior is shared with the
  # multi-skill check below; this just verifies the binding.
  example-skill-reap-exists = mkBatsCheck {
    name = "example-skill-reap-exists";
    env.REAP_SKILL_APP = reapSkillApp;
  };

  # Single-skill uninstall (no args) defaults to the skill the flake
  # was built for.
  example-skill-uninstall-default = mkBatsCheck {
    name = "example-skill-uninstall-default";
    extraInputs = [ pkgs.jq ];
    env = {
      INSTALL_APP = installApp;
      UNINSTALL_SKILL_APP = uninstallSkillApp;
    };
  };

  # ──────────────────────────────────────────────────────────────
  # `extraFiles` checks — loose top-level files at the skill source
  # root (the obra/superpowers case).
  # ──────────────────────────────────────────────────────────────

  # Positive: `extraFiles = [ "*.md" "*.sh" "*.dot" ]` against a source
  # with `visual-companion.md`, `helper.sh`, `graph.dot` at its root
  # ships all three at `$out/share/claude-skills/<name>/<basename>`.
  # The awk-normalized SKILL.md must NOT be clobbered (the `*.md` glob
  # matches SKILL.md too, but the installPhase orders extraFiles before
  # the awk pass so the normalized version wins).
  example-skill-extra-files-ships = mkBatsCheck {
    name = "example-skill-extra-files-ships";
    env.SKILL_ROOT = "${
      fixtureExtraFiles.packages.${system}.default
    }/share/claude-skills/example-skill-extra-files";
  };

  # Negative: same source, no `extraFiles` — the loose top-level files
  # are dropped per the standard whitelist. Regression guard for the
  # default-strict posture.
  example-skill-extra-files-off-drops = mkBatsCheck {
    name = "example-skill-extra-files-off-drops";
    env.SKILL_ROOT = "${
      fixtureExtraFilesOff.packages.${system}.default
    }/share/claude-skills/example-skill-extra-files";
  };

  # Glob with no matches: build succeeds and produces an install with
  # only the canonical surface (SKILL.md + references/), same as no
  # `extraFiles` at all. Mirrors how missing `references/` is silently
  # ignored.
  example-skill-extra-files-no-match = mkBatsCheck {
    name = "example-skill-extra-files-no-match";
    env.SKILL_ROOT = "${
      fixtureExtraFilesNoMatch.packages.${system}.default
    }/share/claude-skills/example-skill-extra-files";
  };

  # `extraFiles = [ "*" ]` against a source with a top-level
  # `companion-dir/` (NOT in `extraDirs`) ships every regular top-level
  # file but NOT the directory — the `[ -f "$f" ]` guard.
  example-skill-extra-files-dir-skip = mkBatsCheck {
    name = "example-skill-extra-files-dir-skip";
    env.SKILL_ROOT = "${
      fixtureExtraFilesDirSkip.packages.${system}.default
    }/share/claude-skills/example-skill-extra-files";
  };

  # ──────────────────────────────────────────────────────────────
  # Rename + frontmatter-normalization checks.
  # ──────────────────────────────────────────────────────────────

  # mkSkill rewrites the installed SKILL.md so its frontmatter `name:`
  # equals the canonical name even when the source declared a different
  # one; store dir + sentinel agree; schemaVersion is 2 and the
  # pre-rename name is recorded as originalSkillName.
  example-skill-rename-normalizes-frontmatter = mkBatsCheck {
    name = "example-skill-rename-normalizes-frontmatter";
    extraInputs = [ pkgs.jq ];
    env.RENAME_SKILL_ROOT = "${renamedSkill}/share/claude-skills/example-skill-renamed";
  };

  # mkAllSkillsFlake's renameFn formula: alpha is discovered and
  # remapped to a name encoding owner + short rev + git date. The
  # renamed name propagates to the store dir, the frontmatter, and the
  # sentinel; the pre-rename name survives as originalSkillName.
  example-skills-dir-rename-fn = mkBatsCheck {
    name = "example-skills-dir-rename-fn";
    extraInputs = [ pkgs.jq ];
    env = {
      RENAMED_ALPHA_PKG = renamedAlphaPkg;
      RENAMED_ALPHA_NAME = renamedAlphaName;
    };
  };

  # A renameFn whose output violates Claude Code's name rule must fail
  # eval (the assertion in mkSkill), not silently build an unloadable
  # skill. tryEval forcing the offending package's drvPath must report
  # failure.
  rename-rejects-invalid-name =
    let
      attempt = builtins.tryEval (
        let
          bad = self.lib.mkAllSkillsFlake {
            inherit nixpkgs;
            skillsDir = ./tests/example-skills-dir;
            name = "invalid-rename";
            namespaceFn = _: "";
            renameFn = _: "Bad_Name";
          };
        in
        builtins.seq bad.packages.${system}."agent-skill-Bad_Name".drvPath true
      );
    in
    mkEvalCheck {
      name = "rename-rejects-invalid-name";
      cond = attempt.success == false;
      msg =
        "rename-rejects-invalid-name: an out-of-spec renamed name "
        + "(uppercase + underscore) must fail eval via the mkSkill name "
        + "assertion, but evaluation succeeded.";
    };

  # ──────────────────────────────────────────────────────────────
  # Multi-skill checks (mkAllSkillsFlake).
  # ──────────────────────────────────────────────────────────────

  # Discovery + aggregate builds: symlinkJoined output contains BOTH
  # alpha and beta SKILL.md files; non-skills are filtered out.
  example-skills-dir-aggregate-builds = mkBatsCheck {
    name = "example-skills-dir-aggregate-builds";
    env.ALL_SKILLS_ROOT = "${allSkills}/share/claude-skills";
  };

  # Per-skill packages exposed as packages.<system>.<name>.
  example-skills-dir-per-skill = mkBatsCheck {
    name = "example-skills-dir-per-skill";
    env = {
      ALPHA_PKG = alphaPkg;
      BETA_PKG = betaPkg;
    };
  };

  # Aggregate install: one symlink + one GC root per skill;
  # $HOME untouched.
  example-skills-dir-install-env = mkBatsCheck {
    name = "example-skills-dir-install-env";
    env.INSTALL_ALL_APP = installAllApp;
  };

  # Idempotency: re-running install when on-disk state already matches
  # the declared set should be a silent no-op. Partial breakage (one
  # symlink or one GC root removed) re-announces only what it had to
  # rewrite.
  example-skills-dir-install-noop = mkBatsCheck {
    name = "example-skills-dir-install-noop";
    env.INSTALL_ALL_APP = installAllApp;
  };

  # ──────────────────────────────────────────────────────────────
  # Install-scope flag coverage (the 9 cases from the
  # install-scope-required plan §1.4).
  # ──────────────────────────────────────────────────────────────

  # Covers: missing --scope, personal, project (git root, git subdir,
  # no-marker fail), custom (with/without --root), subset install
  # (positive + typo).
  install-scope = mkBatsCheck {
    name = "install-scope";
    extraInputs = [ pkgs.git ];
    env.INSTALL_ALL_APP = installAllApp;
  };

  # Codex profile selection: building with `agent = "codex"` puts the
  # install under `.codex/skills/` rather than `.claude/skills/`.
  install-codex-profile = mkBatsCheck {
    name = "install-codex-profile";
    env.INSTALL_CODEX_APP = installCodexApp;
  };

  # Aggregate preview is read-only.
  example-skills-dir-preview-readonly = mkBatsCheck {
    name = "example-skills-dir-preview-readonly";
    extraInputs = [ pkgs.findutils ];
    env.PREVIEW_ALL_APP = previewAllApp;
  };

  # Reap removes a managed-but-broken entry (symlink target gone) and
  # its matching GC root, while leaving unmanaged entries alone.
  example-skills-dir-reap-broken = mkBatsCheck {
    name = "example-skills-dir-reap-broken";
    extraInputs = [ pkgs.jq ];
    env.REAP_ALL_APP = reapAllApp;
  };

  # Single-skill flake exposes a purge app (sibling of reap).
  example-skill-purge-exists = mkBatsCheck {
    name = "example-skill-purge-exists";
    env.PURGE_SKILL_APP = purgeSkillApp;
  };

  # Purge removes EVERY live lineage entry (no declared set, no names) and
  # their GC roots + lock entries, while leaving unmanaged entries alone.
  example-skills-dir-purge = mkBatsCheck {
    name = "example-skills-dir-purge";
    extraInputs = [ pkgs.jq ];
    env = {
      INSTALL_ALL_APP = installAllApp;
      PURGE_ALL_APP = purgeAllApp;
    };
  };

  # Purge --dry-run lists what would go and changes nothing; a
  # non-interactive run without --yes/--dry-run refuses.
  example-skills-dir-purge-dry-run = mkBatsCheck {
    name = "example-skills-dir-purge-dry-run";
    env = {
      INSTALL_ALL_APP = installAllApp;
      PURGE_ALL_APP = purgeAllApp;
    };
  };

  # Reconcile installs the declared set AND sweeps stray managed
  # entries while leaving unmanaged entries alone.
  example-skills-dir-reconcile = mkBatsCheck {
    name = "example-skills-dir-reconcile";
    extraInputs = [ pkgs.jq ];
    env = {
      ALPHA_PKG = alphaPkg;
      RECONCILE_ALL_APP = reconcileAllApp;
    };
  };

  # Idempotency mirror of install-noop: a second reconcile with state
  # already in sync skips the per-skill `reconciled (install): …`
  # output; partial breakage re-announces only the broken entries.
  example-skills-dir-reconcile-noop = mkBatsCheck {
    name = "example-skills-dir-reconcile-noop";
    env.RECONCILE_ALL_APP = reconcileAllApp;
  };

  # ──────────────────────────────────────────────────────────────
  # Lock file + uninstall checks.
  # ──────────────────────────────────────────────────────────────

  # Install populates the aggregate lock with one entry per installed
  # skill, copying provenance from the per-skill sentinel. Reap,
  # reconcile, and uninstall all read/write the same file.
  example-skills-dir-install-writes-lock = mkBatsCheck {
    name = "example-skills-dir-install-writes-lock";
    extraInputs = [ pkgs.jq ];
    env.INSTALL_ALL_APP = installAllApp;
  };

  # Uninstall (multi-skill): removes one named entry — symlink,
  # GC root, and lock entry — leaves the other alone.
  example-skills-dir-uninstall = mkBatsCheck {
    name = "example-skills-dir-uninstall";
    extraInputs = [ pkgs.jq ];
    env = {
      INSTALL_ALL_APP = installAllApp;
      UNINSTALL_ALL_APP = uninstallAllApp;
    };
  };

  # Uninstall refuses to touch entries it didn't install (manual skill
  # dirs / foreign-lineage symlinks).
  example-skills-dir-uninstall-refuses-unmanaged = mkBatsCheck {
    name = "example-skills-dir-uninstall-refuses-unmanaged";
    env.UNINSTALL_ALL_APP = uninstallAllApp;
  };

  # Reap drops the lock entry along with the symlink + GC root.
  example-skills-dir-reap-prunes-lock = mkBatsCheck {
    name = "example-skills-dir-reap-prunes-lock";
    extraInputs = [ pkgs.jq ];
    env.REAP_ALL_APP = reapAllApp;
  };

  # Reconcile rewrites the lock to match the declared set exactly —
  # stray entries dropped, declared entries refreshed.
  example-skills-dir-reconcile-rewrites-lock = mkBatsCheck {
    name = "example-skills-dir-reconcile-rewrites-lock";
    extraInputs = [ pkgs.jq ];
    env.RECONCILE_ALL_APP = reconcileAllApp;
  };

  # ──────────────────────────────────────────────────────────────
  # homeManagerModules.default — primary activation surface.
  # ──────────────────────────────────────────────────────────────

  # Home-manager module evaluates: writes a non-empty
  # `home.activation.flakeSkillsReconcile.data` that invokes both the
  # reconcile and reap binaries. Pure string assertion on the evaluated
  # activation text — no filesystem effects.
  home-manager-module-evaluates =
    let
      eval = nixpkgs.lib.evalModules {
        specialArgs.lib = mockHomeManagerLib;
        modules = [
          mockHomeManager
          self.homeManagerModules.default
          {
            _module.args.pkgs = pkgs;
            programs.agent-skill-flake.enable = true;
            programs.agent-skill-flake.scope = "personal";
            programs.agent-skill-flake.skills = [
              alphaPkg
              betaPkg
            ];
          }
        ];
      };
      data = eval.config.home.activation.flakeSkillsReconcile.data;
    in
    mkEvalCheck {
      name = "home-manager-module-evaluates";
      cond =
        data != ""
        && lib.hasInfix "/bin/reconcile-home-manager" data
        && lib.hasInfix "/bin/reap-home-manager" data
        && lib.hasInfix "--scope=personal" data;
      msg =
        "home-manager-module-evaluates: activation data must invoke "
        + "reconcile + reap with --scope=personal; got:\n${data}";
    };

  # autoDiscover flag: when `true`, packages in `home.packages` that
  # carry `passthru.isFlakeSkill` are reconciled in addition to whatever
  # is in `skills`. Default (`false`) must leave them out. The gating is
  # observable in the skill list baked into the generated reconcile
  # script, which we read back (IFD) and inspect.
  home-manager-module-autodiscovers =
    let
      evalWith =
        {
          autoDiscover,
          homePackages,
          skills,
        }:
        nixpkgs.lib.evalModules {
          specialArgs.lib = mockHomeManagerLib;
          modules = [
            mockHomeManager
            self.homeManagerModules.default
            {
              _module.args.pkgs = pkgs;
              programs.agent-skill-flake.enable = true;
              programs.agent-skill-flake.scope = "personal";
              programs.agent-skill-flake.skills = skills;
              programs.agent-skill-flake.autoDiscover = autoDiscover;
              home.packages = homePackages;
            }
          ];
        };

      # The activation data is now
      # `<reconcile>/bin/... --scope=...\n<reap>/bin/... --scope=...\n`;
      # the first line is the reconcile invocation. Read just the binary
      # path (chopping off the args after the first space) to see which
      # skills were baked in.
      reconcileScript =
        ev:
        let
          data = ev.config.home.activation.flakeSkillsReconcile.data;
          firstLine = builtins.head (lib.splitString "\n" data);
          reconcileBin = builtins.head (lib.splitString " " firstLine);
        in
        builtins.readFile reconcileBin;

      onScript = reconcileScript (evalWith {
        autoDiscover = true;
        homePackages = [
          alphaPkg
          betaPkg
          pkgs.hello
        ];
        skills = [ ];
      });
      offScript = reconcileScript (evalWith {
        autoDiscover = false;
        homePackages = [
          alphaPkg
          betaPkg
        ];
        skills = [ ];
      });
    in
    mkEvalCheck {
      name = "home-manager-module-autodiscovers";
      cond =
        # autoDiscover = true: alpha + beta picked up from home.packages;
        # the unrelated `hello` is filtered out.
        lib.hasInfix ''"alpha:/nix/store/'' onScript
        && lib.hasInfix ''"beta:/nix/store/'' onScript
        && !(lib.hasInfix ''"hello:'' onScript)
        # autoDiscover = false (default): empty skills list, so neither
        # alpha nor beta is referenced.
        && !(lib.hasInfix ''"alpha:/nix/store/'' offScript)
        && !(lib.hasInfix ''"beta:/nix/store/'' offScript);
      msg =
        "home-manager-module-autodiscovers: autoDiscover gating wrong "
        + "(alpha/beta should appear only with autoDiscover=true, never hello)";
    };

  # ──────────────────────────────────────────────────────────────
  # mkSkillsEnv — multi-skill env (`pkgs.buildEnv` analogue).
  # ──────────────────────────────────────────────────────────────

  # `mkSkillsEnv` must produce a `symlinkJoin`-style drv that:
  #   - includes every member skill's files (via symlinks), AND
  #   - carries `passthru.isFlakeSkillsEnv = true` plus a
  #     `flakeSkillsEnv = [{ name; drv; }]` list keyed by each
  #     member's `passthru.flakeSkillName`.
  # The contract is what lets the home-manager-module expand a single
  # env entry back into per-skill records on activation.
  mk-skills-env-passthru =
    let
      env = self.lib.mkSkillsEnv {
        inherit pkgs;
        name = "skills-env-alpha-beta";
        skills = [
          alphaPkg
          betaPkg
        ];
      };
    in
    mkEvalCheck {
      name = "mk-skills-env-passthru";
      cond =
        (env.passthru.isFlakeSkillsEnv or false)
        && (builtins.length env.passthru.flakeSkillsEnv == 2)
        && (lib.elem "alpha" (map (m: m.name) env.passthru.flakeSkillsEnv))
        && (lib.elem "beta" (map (m: m.name) env.passthru.flakeSkillsEnv))
        && (lib.all (
          m: m.drv ? passthru && m.drv.passthru.isFlakeSkill or false
        ) env.passthru.flakeSkillsEnv);
      msg =
        "mk-skills-env-passthru: env must carry isFlakeSkillsEnv=true "
        + "and flakeSkillsEnv=[{name=alpha; ...} {name=beta; ...}] with "
        + "each member's drv carrying isFlakeSkill=true.";
    };

  # Passing a skills-env into `programs.agent-skill-flake.skills` must expand
  # back into its member skills in the reconcile script — so a single
  # env entry installs N separate `~/.claude/skills/<name>/` trees, not
  # one nested env tree.
  home-manager-module-expands-skills-env =
    let
      env = self.lib.mkSkillsEnv {
        inherit pkgs;
        name = "skills-env-alpha-beta";
        skills = [
          alphaPkg
          betaPkg
        ];
      };
      eval = nixpkgs.lib.evalModules {
        specialArgs.lib = mockHomeManagerLib;
        modules = [
          mockHomeManager
          self.homeManagerModules.default
          {
            _module.args.pkgs = pkgs;
            programs.agent-skill-flake.enable = true;
            programs.agent-skill-flake.scope = "personal";
            programs.agent-skill-flake.skills = [ env ];
          }
        ];
      };
      data = eval.config.home.activation.flakeSkillsReconcile.data;
      reconcileBin = builtins.head (lib.splitString " " (builtins.head (lib.splitString "\n" data)));
      script = builtins.readFile reconcileBin;
    in
    mkEvalCheck {
      name = "home-manager-module-expands-skills-env";
      cond = lib.hasInfix ''"alpha:/nix/store/'' script && lib.hasInfix ''"beta:/nix/store/'' script;
      msg =
        "home-manager-module-expands-skills-env: reconcile script must "
        + "contain per-member `name:store-path` entries for both alpha and "
        + "beta after expansion, but at least one is missing.";
    };

  # ──────────────────────────────────────────────────────────────
  # withNamePrefix — consumer-side prefix wrapper.
  # ──────────────────────────────────────────────────────────────

  # Wrapping a single skill: install dir, frontmatter, sentinel are all
  # rewritten to the prefixed name. originalSkillName + managedBy are
  # preserved so traceability back to the upstream lineage survives.
  with-name-prefix-single = mkBatsCheck {
    name = "with-name-prefix-single";
    extraInputs = [ pkgs.jq ];
    env.WRAPPED_SKILL_ROOT = "${wrappedSingle}/share/claude-skills/${wrappedSingleName}";
  };

  # Wrapping a skills env: every member dir is prefix-renamed, frontmatter
  # and sentinel match per member, originals don't survive.
  with-name-prefix-env = mkBatsCheck {
    name = "with-name-prefix-env";
    extraInputs = [ pkgs.jq ];
    env.WRAPPED_ENV_ROOT = "${wrappedEnv}/share/claude-skills";
  };

  # The wrapped env carries `isFlakeSkillsEnv = true` and a
  # `flakeSkillsEnv` list whose members carry `isFlakeSkill = true`
  # under prefixed names — the contract home-manager activation relies
  # on to expand the env into per-skill records.
  with-name-prefix-passthru = mkEvalCheck {
    name = "with-name-prefix-passthru";
    cond =
      (wrappedSingle.passthru.isFlakeSkill or false)
      && wrappedSingle.passthru.flakeSkillName == wrappedSingleName
      && (wrappedEnv.passthru.isFlakeSkillsEnv or false)
      && (builtins.length wrappedEnv.passthru.flakeSkillsEnv == 2)
      && (lib.elem "superpowers-alpha" (map (m: m.name) wrappedEnv.passthru.flakeSkillsEnv))
      && (lib.elem "superpowers-beta" (map (m: m.name) wrappedEnv.passthru.flakeSkillsEnv))
      && (lib.all (
        m: m.drv ? passthru && (m.drv.passthru.isFlakeSkill or false)
      ) wrappedEnv.passthru.flakeSkillsEnv);
    msg =
      "with-name-prefix-passthru: wrapped single must carry "
      + "isFlakeSkill=true + flakeSkillName='${wrappedSingleName}'; wrapped "
      + "env must carry isFlakeSkillsEnv=true and flakeSkillsEnv=["
      + "{name=superpowers-alpha;...} {name=superpowers-beta;...}] with "
      + "each drv carrying isFlakeSkill=true.";
  };

  # A wrapped env passed into `programs.agent-skill-flake.skills` must expand
  # back into its prefixed members in the reconcile script — so home-manager
  # activation actually installs `superpowers-alpha/` and `superpowers-beta/`,
  # not a nested env tree.
  with-name-prefix-home-manager-expands =
    let
      eval = nixpkgs.lib.evalModules {
        specialArgs.lib = mockHomeManagerLib;
        modules = [
          mockHomeManager
          self.homeManagerModules.default
          {
            _module.args.pkgs = pkgs;
            programs.agent-skill-flake.enable = true;
            programs.agent-skill-flake.scope = "personal";
            programs.agent-skill-flake.skills = [ wrappedEnv ];
          }
        ];
      };
      data = eval.config.home.activation.flakeSkillsReconcile.data;
      reconcileBin = builtins.head (lib.splitString " " (builtins.head (lib.splitString "\n" data)));
      script = builtins.readFile reconcileBin;
    in
    mkEvalCheck {
      name = "with-name-prefix-home-manager-expands";
      cond =
        lib.hasInfix ''"superpowers-alpha:/nix/store/'' script
        && lib.hasInfix ''"superpowers-beta:/nix/store/'' script
        # The originals must not leak through alongside the prefixed
        # versions — that would double-install under both names.
        && !(lib.hasInfix ''"alpha:/nix/store/'' script)
        && !(lib.hasInfix ''"beta:/nix/store/'' script);
      msg =
        "with-name-prefix-home-manager-expands: reconcile script must "
        + "contain per-member `superpowers-{alpha,beta}:store-path` lines "
        + "and must NOT contain the unprefixed `{alpha,beta}:store-path` "
        + "lines, but the assertion failed.";
    };

  # An invalid `namePrefix` (uppercase, underscore, …) must fail eval
  # with a clear message — same posture as `rename-rejects-invalid-name`.
  with-name-prefix-rejects-invalid =
    let
      attempt = builtins.tryEval (
        let
          bad = self.lib.withNamePrefix {
            inherit pkgs;
            namePrefix = "Bad_Prefix";
            skill = skill;
          };
        in
        builtins.seq bad.drvPath true
      );
    in
    mkEvalCheck {
      name = "with-name-prefix-rejects-invalid";
      cond = attempt.success == false;
      msg =
        "with-name-prefix-rejects-invalid: a namePrefix violating "
        + "^[a-z0-9][a-z0-9-]*$ must fail eval, but evaluation succeeded.";
    };

  # ──────────────────────────────────────────────────────────────
  # Marketplace / aggregation helpers.
  # ──────────────────────────────────────────────────────────────

  # `lib.mkInstaller` builds a working installer over an arbitrary
  # [{name;drv;}] set and produces `bin/install-<appName>` — no internal.nix
  # import. Running it with a scope writes the expected symlinks + GC roots.
  mk-installer-arbitrary = mkBatsCheck {
    name = "mk-installer-arbitrary";
    env.ARBITRARY_INSTALL_APP = arbitraryInstallApp;
  };

  # `lib.mkPrefixedInstaller` installs the prefixed names end-to-end.
  mk-prefixed-installer = mkBatsCheck {
    name = "mk-prefixed-installer";
    extraInputs = [ pkgs.git ];
    env.PREFIXED_INSTALL_APP = prefixedInstallApp;
  };

  # `lib.withNamePrefixSource` returns one {name;drv;} per source skill,
  # names are `<prefix>-<old>`, each drv is a real flake-skill, and the
  # source's default/aggregate keys are excluded (filtered by packagePrefix).
  with-name-prefix-source = mkEvalCheck {
    name = "with-name-prefix-source";
    cond =
      (builtins.length prefixedSourceSet == 2)
      && (lib.elem "src-alpha" (map (s: s.name) prefixedSourceSet))
      && (lib.elem "src-beta" (map (s: s.name) prefixedSourceSet))
      && (lib.all (s: s.drv.passthru.isFlakeSkill or false) prefixedSourceSet)
      && (lib.all (s: s.drv.passthru.flakeSkillName == s.name) prefixedSourceSet);
    msg =
      "with-name-prefix-source: expected exactly [{name=src-alpha;...} "
      + "{name=src-beta;...}] with each drv carrying isFlakeSkill=true and a "
      + "matching flakeSkillName; the source's default/aggregate keys must be "
      + "filtered out.";
  };

  # `lib.installCommandFor` returns the right string for all four arms of the
  # prefix × subset cross-product.
  install-command-for =
    let
      arm1 = installCmd { source = fixtureAll; };
      arm2 = installCmd {
        source = fixtureAll;
        skills = [ "alpha" ];
      };
      arm3 = installCmd {
        source = fixtureAll;
        prefix = "src";
      };
      arm4 = installCmd {
        source = fixtureAll;
        prefix = "src";
        skills = [ "src-alpha" ];
      };
    in
    mkEvalCheck {
      name = "install-command-for";
      cond =
        arm1 == "${baseInstallProgram} --scope=project"
        && arm2 == "${baseInstallProgram} --scope=project alpha"
        && lib.hasInfix "/bin/install-agent-skills-src-all --scope=project" arm3
        && !(lib.hasInfix "alpha" arm3)
        && lib.hasInfix "/bin/install-agent-skills-src-all --scope=project src-alpha" arm4;
      msg =
        "install-command-for: one of the four arms (prefix × subset) produced "
        + "the wrong install string. Got:\n"
        + "  arm1=${arm1}\n  arm2=${arm2}\n  arm3=${arm3}\n  arm4=${arm4}";
    };

  # `lib.mkAggregateSkillsFlake` merges base + every source's keys, and the
  # latent verbatim-merge bug stays fixed: a source's `default` / aggregate
  # keys never leak into the merge, so the base aggregates survive.
  aggregate-skills-flake-merge = mkEvalCheck {
    name = "aggregate-skills-flake-merge";
    cond =
      # base skills.
      (aggPkgs ? "agent-skill-alpha")
      && (aggPkgs ? "agent-skill-beta")
      # verbatim (non-prefixed) source.
      && (aggPkgs ? "agent-skill-gamma")
      # prefixed source.
      && (aggPkgs ? "agent-skill-src-alpha")
      && (aggPkgs ? "agent-skill-src-beta")
      # base aggregate keys present (the `default` alias + the base's own
      # `name`)...
      && (aggPkgs ? "default")
      && (aggPkgs ? "aggregate-base")
      # ...and they are *base's* (name "aggregate-base"), proving no source
      # default/aggregate overwrote them.
      && lib.hasInfix "aggregate-base" aggPkgs.default.name
      && lib.hasInfix "aggregate-base" aggPkgs."aggregate-base".name
      # The sources' aggregate names must not have leaked in as keys.
      && !(aggPkgs ? "source-gamma")
      && !(aggPkgs ? "example-skills-dir");
    msg =
      "aggregate-skills-flake-merge: merged package set must contain base "
      + "(agent-skill-alpha/beta) + verbatim source (agent-skill-gamma) + "
      + "prefixed source (agent-skill-src-alpha/beta), with default and the "
      + "base aggregate key (aggregate-base) still pointing at the base "
      + "aggregate and no source aggregate leaking in.";
  };

  # `reconcileScript system` is the declarative dev-shell one-liner: the
  # combined reconcile binary over the union at --scope=project. It is a
  # single command — one owner of the target.
  aggregate-skills-flake-reconcile-script =
    let
      script = agg.reconcileScript system;
    in
    mkEvalCheck {
      name = "aggregate-skills-flake-reconcile-script";
      cond =
        lib.hasInfix "/bin/reconcile-aggregate-base --scope=project" script && !(lib.hasInfix "\n" script);
      msg =
        "aggregate-skills-flake-reconcile-script: expected a single "
        + "reconcile-aggregate-base --scope=project invocation. Got:\n${script}";
    };

  # Convergence (the git-skills stray-leftover regression): the full union
  # installs base + a prefixed source (src-gamma); reconciling with the
  # reduced aggregate (same appName, source dropped) sweeps src-gamma and
  # leaves base alone. Both reconciles share appName "converge" so the
  # second recognizes the first's installs as its own.
  aggregate-reconcile-converges = mkBatsCheck {
    name = "aggregate-reconcile-converges";
    env = {
      RECONCILE_FULL_APP = aggConvergeFullReconcile;
      RECONCILE_REDUCED_APP = aggConvergeReducedReconcile;
    };
  };

  # Idempotence: a second combined reconcile with state already in sync is
  # a silent no-op (no per-skill `reconciled (install): …` lines), matching
  # the silent-no-op behavior from #13.
  aggregate-reconcile-idempotent = mkBatsCheck {
    name = "aggregate-reconcile-idempotent";
    env.RECONCILE_FULL_APP = aggConvergeFullReconcile;
  };

  # Coexistence (scoped ownership): two aggregates installing into one
  # target each sweep only their own strays. Re-running A's reconcile must
  # not touch B's gamma, and vice versa.
  aggregate-reconcile-coexists = mkBatsCheck {
    name = "aggregate-reconcile-coexists";
    env = {
      RECONCILE_A_APP = aggCoexistAReconcile;
      RECONCILE_B_APP = aggCoexistBReconcile;
    };
  };

  # Cherry-pick (per-source `skills`): only the selected skill installs; the
  # dropped sibling never lands. Covers both the verbatim source arm (`alpha`
  # kept, `beta` dropped) and the prefixed arm (`px-alpha` kept, `px-beta`
  # dropped) — the regression for the `skills` field the reconcile rewrite
  # ignored.
  aggregate-cherry-pick = mkBatsCheck {
    name = "aggregate-cherry-pick";
    env = {
      RECONCILE_VERBATIM_APP = aggCherryPickReconcile;
      RECONCILE_PREFIXED_APP = aggCherryPickPrefixedReconcile;
    };
  };

  # The package-set arm of the same filter: the aggregate exposes exactly the
  # cherry-picked skill's key and not the dropped sibling's, for both the
  # verbatim (`agent-skill-alpha`) and prefixed (`agent-skill-px-alpha`)
  # sources. Guards the half of `recordsForSource` the bats check (install
  # side) doesn't see.
  aggregate-cherry-pick-packages = mkEvalCheck {
    name = "aggregate-cherry-pick-packages";
    cond =
      builtins.attrNames fixtureAggCherryPick.packages.${system} == [ "agent-skill-alpha" ]
      && builtins.attrNames fixtureAggCherryPickPrefixed.packages.${system} == [ "agent-skill-px-alpha" ];
    msg = "cherry-pick package set must contain only the selected skill's key";
  };

  # ──────────────────────────────────────────────────────────────
  # mkCombination — an aggregate that is also a source, plus an env.
  # ──────────────────────────────────────────────────────────────

  # Source-ability (the dropped-`packages` regression): re-aggregating a
  # combination must surface its prefixed key. Fails against the old
  # hand-wrapped shape (no `packages`); passes with the helper.
  combination-source-able = mkEvalCheck {
    name = "combination-source-able";
    cond = fixtureCombinationReused.packages.${system} ? "agent-skill-cx-gamma";
    msg =
      "combination-source-able: re-aggregating a combination as a source "
      + "must expose its prefixed key (agent-skill-cx-gamma), proving a combination "
      + "is itself a valid mkAggregateSkillsFlake source. Got keys: "
      + lib.concatStringsSep ", " (builtins.attrNames fixtureCombinationReused.packages.${system});
  };

  # ──────────────────────────────────────────────────────────────
  # Owner-namespaced package keys + duplicate-install-name guards.
  # ──────────────────────────────────────────────────────────────

  # The default `namespaceFn` (ctx.source.owner) namespaces package keys by
  # owner while the installed identity stays bare.
  package-key-owner-namespaced =
    let
      ownerPkgs = fixtureAllOwner.packages.${system};
    in
    mkEvalCheck {
      name = "package-key-owner-namespaced";
      cond =
        (ownerPkgs ? "agent-skill-acme-alpha")
        && (ownerPkgs ? "agent-skill-acme-beta")
        && (ownerPkgs ? "agent-skills-acme-all")
        && (ownerPkgs ? "default")
        && ownerPkgs."agent-skill-acme-alpha".passthru.flakeSkillName == "alpha";
      msg =
        "package-key-owner-namespaced: the source owner must namespace package "
        + "keys (agent-skill-acme-alpha, agent-skills-acme-all) while the "
        + "installed skill name stays bare (alpha).";
    };

  # `bySkillName` indexes per-skill drvs by bare installed name, excluding
  # the aggregate envs, regardless of how the package keys are namespaced.
  by-skill-name-output = mkEvalCheck {
    name = "by-skill-name-output";
    cond =
      (fixtureAll.bySkillName.${system} ? "alpha")
      && (fixtureAll.bySkillName.${system} ? "beta")
      && !(fixtureAll.bySkillName.${system} ? "default")
      && (fixtureAllOwner.bySkillName.${system} ? "alpha")
      && fixtureAllOwner.bySkillName.${system}.alpha.passthru.flakeSkillName == "alpha";
    msg =
      "by-skill-name-output: bySkillName must index per-skill drvs by bare "
      + "installed name (excluding aggregates), regardless of key namespace.";
  };

  # `namespaceFn = _: ""` opts out: keys are the bare `agent-skill-<name>`.
  package-key-namespace-omitted = mkEvalCheck {
    name = "package-key-namespace-omitted";
    cond =
      (fixtureAll.packages.${system} ? "agent-skill-alpha")
      && !(fixtureAll.packages.${system} ? "agent-skill-acme-alpha");
    msg = "package-key-namespace-omitted: an empty namespace must yield bare agent-skill-<name> keys.";
  };

  # Recursive discovery: skills nested under grouping folders
  # (group-one/nested-alpha, group-two/deeper/nested-beta) are found at any
  # depth, a depth-1 skill (top-flat) still works alongside them, and a
  # grouping folder with no SKILL.md beneath it contributes nothing.
  discover-skills-recursive =
    let
      nested =
        (self.lib.mkAllSkillsFlake {
          inherit nixpkgs;
          skillsDir = ./tests/example-nested-dir;
          namespaceFn = _: "";
        }).packages.${system};
    in
    mkEvalCheck {
      name = "discover-skills-recursive";
      cond =
        (nested ? "agent-skill-top-flat")
        && (nested ? "agent-skill-nested-alpha")
        && (nested ? "agent-skill-nested-beta")
        && !(nested ? "agent-skill-group-one")
        && !(nested ? "agent-skill-group-two")
        && !(nested ? "agent-skill-deeper")
        && !(nested ? "agent-skill-empty-group")
        && !(nested ? "agent-skill-not-a-skill");
      msg = "discover-skills-recursive: skills must be discovered at any depth and group folders must never become skills.";
    };

  # mkDevshellSkillsFlake surfaces a single combination as runnable apps
  # (reconcile = converge, purge = remove-all — the verbs the root devShell
  # wiring invokes at runtime; reap = prune-broken) and re-exposes the union's
  # per-skill packages as a composable source.
  devshell-skills-flake =
    let
      dsf = self.lib.mkDevshellSkillsFlake {
        inherit nixpkgs;
        name = "fixture-devshell";
        sources = [ { source = fixtureAll; } ];
      };
    in
    mkEvalCheck {
      name = "devshell-skills-flake";
      cond =
        (dsf.apps.${system} ? reconcile)
        && (dsf.apps.${system} ? purge)
        && (dsf.apps.${system} ? reap)
        && (dsf.packages.${system} ? "agent-skill-alpha")
        && (dsf.combinations ? default);
      msg = "devshell-skills-flake: must surface reconcile/purge/reap apps and the union's per-skill packages.";
    };

  # With `envName` omitted, mkDevshellSkillsFlake's default must be
  # `agent-skills-${name}` — the shared `agent-skills-` namespace prefix
  # mkAllSkillsFlake uses — so consumers can drop the (mechanical) explicit
  # envName and still get the identical home-manager env package name.
  devshell-skills-flake-default-env-name =
    let
      dsf = self.lib.mkDevshellSkillsFlake {
        inherit nixpkgs;
        name = "fixture-devshell";
        sources = [ { source = fixtureAll; } ];
      };
    in
    mkEvalCheck {
      name = "devshell-skills-flake-default-env-name";
      cond = dsf.combinations.default.env.${system}.name == "agent-skills-fixture-devshell";
      msg =
        "devshell-skills-flake-default-env-name: with envName omitted, the env "
        + "name must default to agent-skills-<name>. Got: "
        + dsf.combinations.default.env.${system}.name;
    };

  # `devshellSkillsHook` exposes `standardCommands` — the repo-agnostic
  # ci/dev/maintenance trio (check / fmt / update-flake) every consumer
  # otherwise re-hand-rolls. Imports the hook as the pure function it is
  # and asserts all three entries verbatim — including `help`, so help-text
  # drift breaks CI too (the whole point of factoring them out).
  devshell-hook-standard-commands =
    let
      cmds = (import ./lib/devshell-skills-hook.nix { }).standardCommands;
    in
    mkEvalCheck {
      name = "devshell-hook-standard-commands";
      cond =
        builtins.length cmds == 3
        &&
          cmds == [
            {
              category = "ci";
              name = "check";
              help = "Run the full test suite via nix flake check";
              command = ''nix flake check "$@"'';
            }
            {
              category = "dev";
              name = "fmt";
              help = "Format the tree with treefmt (nixfmt + shfmt)";
              command = ''nix fmt "$@"'';
            }
            {
              category = "maintenance";
              name = "update-flake";
              help = "Update all flake inputs and rewrite flake.lock";
              command = ''nix flake update "$@"'';
            }
          ];
      msg =
        "devshell-hook-standard-commands: standardCommands must be exactly the "
        + "ci/dev/maintenance trio (check / fmt / update-flake) with matching "
        + "category, name, help, and command. Got:\n"
        + builtins.toJSON cmds;
    };

  # ──────────────────────────────────────────────────────────────
  # flakeModules.devshellSkills — the exposed dev-shell flake-parts module.
  # ──────────────────────────────────────────────────────────────

  # End-to-end check on the module via this repo's OWN dogfooded devShell
  # (flake.nix imports lib/devshell-skills-flake-module.nix). Asserts the
  # assembled command set carries the three standard categories (ci/check,
  # dev/fmt, maintenance/update-flake) AND the two skills commands
  # (reap-skills, update-skills-devshell), and that the install-skills startup
  # reconciles the sub-flake at project scope. This is the whole point of the
  # module: a consumer importing it gets exactly this wiring with no hand-roll.
  devshell-skills-flake-module =
    let
      shell = self.devShells.${system}.default.config;
      cmds = shell.commands;
      hasCmd = cat: nm: lib.any (c: c.category == cat && c.name == nm) cmds;
      startup = shell.devshell.startup.install-skills.text;
    in
    mkEvalCheck {
      name = "devshell-skills-flake-module";
      cond =
        # ci/dev/maintenance trio.
        hasCmd "ci" "check"
        && hasCmd "dev" "fmt"
        && hasCmd "maintenance" "update-flake"
        # the two skills commands.
        && hasCmd "skills" "reap-skills"
        && hasCmd "skills" "update-skills-devshell"
        # install-skills startup reconciles the sub-flake at project scope.
        && lib.hasInfix "reconcile" startup
        && lib.hasInfix "--scope=project" startup;
      msg =
        "devshell-skills-flake-module: the dogfooded devShell must carry the "
        + "ci/dev/maintenance trio (check/fmt/update-flake), both skills "
        + "commands (reap-skills/update-skills-devshell), and an install-skills "
        + "startup that reconciles at --scope=project. Got commands:\n"
        + builtins.toJSON (map (c: "${c.category}/${c.name}") cmds)
        + "\nstartup: ${startup}";
    };

  # Coverage of the EXPORTED artifact (what consumers actually receive), not
  # the dogfood path the check above exercises. The exported
  # `flake.flakeModules.devshellSkills` must be an attrset with an `imports`
  # list bundling the local module file, and `flakeModules.default` must be the
  # very same bundle. A lightweight eval check — a deep `mkFlake` instantiation
  # of the bundle is heavy and unnecessary to assert these structural
  # guarantees.
  flake-module-devshell-skills-exported =
    let
      bundle = self.flakeModules.devshellSkills;
      imports = bundle.imports or [ ];
      # The local module is imported by relative path; in the exported flake it
      # resolves to a store path whose basename is the module file. Match on
      # that basename so the check doesn't pin the full store path.
      bundlesLocalModule = lib.any (
        m: lib.isString (toString m) && lib.hasSuffix "devshell-skills-flake-module.nix" (toString m)
      ) imports;
    in
    mkEvalCheck {
      name = "flake-module-devshell-skills-exported";
      cond =
        lib.isAttrs bundle
        && lib.isList imports
        && bundlesLocalModule
        # `default` is an alias of the named bundle.
        && self.flakeModules.default == bundle;
      msg =
        "flake-module-devshell-skills-exported: flake.flakeModules.devshellSkills "
        + "must be an attrset whose `imports` list contains "
        + "devshell-skills-flake-module.nix, and flakeModules.default must equal "
        + "it. Got imports: "
        + builtins.toJSON (map toString imports);
    };

  # No `source` (owner unresolvable) under the default `namespaceFn` is a
  # hard eval error, never a silently un-namespaced key.
  namespace-null-throws = mkEvalCheck {
    name = "namespace-null-throws";
    cond =
      (builtins.tryEval (
        builtins.attrNames
          (self.lib.mkAllSkillsFlake {
            inherit nixpkgs;
            skillsDir = ./tests/example-skills-dir;
          }).packages.${system}
      )).success == false;
    msg = "namespace-null-throws: a null namespace (no source) must fail eval, not produce un-namespaced keys.";
  };

  # A local/ownerless source URL resolves the owner to null → same hard error.
  namespace-local-url-throws = mkEvalCheck {
    name = "namespace-local-url-throws";
    cond =
      (builtins.tryEval (
        builtins.attrNames
          (self.lib.mkAllSkillsFlake {
            inherit nixpkgs;
            skillsDir = ./tests/example-skills-dir;
            source = {
              url = "git+file:///Users/me/myrepo";
            };
          }).packages.${system}
      )).success == false;
    msg = "namespace-local-url-throws: a local (ownerless) source URL must fail eval.";
  };

  # Two distinct skills that install under the same name must fail when
  # bundled into one env.
  env-duplicate-name-throws =
    let
      mkDup =
        src:
        (self.lib.mkSkillFlake {
          inherit nixpkgs src;
          skillName = "dup";
          namespaceFn = _: "";
        }).packages.${system}.default;
      attempt = builtins.tryEval (
        builtins.seq
          (self.lib.mkSkillsEnv {
            inherit pkgs;
            name = "dup-env";
            skills = [
              (mkDup ./tests/example-skill)
              (mkDup ./tests/example-skill-rename)
            ];
          }).drvPath
          true
      );
    in
    mkEvalCheck {
      name = "env-duplicate-name-throws";
      cond = attempt.success == false;
      msg = "env-duplicate-name-throws: two distinct skills sharing an install name must fail in mkSkillsEnv.";
    };

  # The same collision across two combination sources (distinct package
  # keys, same install name) must fail the union guard.
  combination-duplicate-name-throws =
    let
      collide = self.lib.mkCombination {
        inherit nixpkgs;
        name = "collide";
        sources = [
          {
            source = self.lib.mkAllSkillsFlake {
              inherit nixpkgs;
              skillsDir = ./tests/example-skills-dir;
              name = "collide-a";
              namespaceFn = _: "";
            };
          }
          {
            # Distinct package key (namespace "x") but the same install name
            # "alpha" as the source above — isolates the install-name guard
            # from the package-key guard.
            source = self.lib.mkSkillFlake {
              inherit nixpkgs;
              skillName = "alpha";
              src = ./tests/example-skill;
              namespaceFn = _: "x";
            };
          }
        ];
      };
      attempt = builtins.tryEval (builtins.seq collide.apps.${system}.reconcile.program true);
    in
    mkEvalCheck {
      name = "combination-duplicate-name-throws";
      cond = attempt.success == false;
      msg = "combination-duplicate-name-throws: two sources installing the same name must fail the union guard.";
    };

  # A per-source `prefix` resolves what would otherwise be a duplicate
  # install name, so the union builds and exposes all three keys.
  combination-prefix-resolves-collision = mkEvalCheck {
    name = "combination-prefix-resolves-collision";
    cond =
      (fixtureCombinationPrefixResolves.packages.${system} ? "agent-skill-alpha")
      && (fixtureCombinationPrefixResolves.packages.${system} ? "agent-skill-beta")
      && (fixtureCombinationPrefixResolves.packages.${system} ? "agent-skill-bx-alpha")
      && builtins.seq fixtureCombinationPrefixResolves.env.${system}.drvPath true;
    msg = "combination-prefix-resolves-collision: a per-source prefix must resolve a duplicate install name.";
  };

  # A source entry's `pack` cherry-picks exactly the named bundle's members
  # (here `agent-skills-pack-mini` = just `alpha`), read from the env, then
  # `prefix` brands them — so the union has `agent-skill-fp-alpha` and not beta.
  combination-pack-selects-bundle-members = mkEvalCheck {
    name = "combination-pack-selects-bundle-members";
    cond =
      (fixtureCombinationFromPack.packages.${system} ? "agent-skill-fp-alpha")
      && !(fixtureCombinationFromPack.packages.${system} ? "agent-skill-fp-beta");
    msg = "combination-pack-selects-bundle-members: `pack` must cherry-pick exactly the bundle's members.";
  };

  # The added surface: `env.<sys>` is a single mkSkillsEnv derivation
  # (`isFlakeSkillsEnv`) whose members are the combination's prefixed skills.
  combination-env = mkEvalCheck {
    name = "combination-env";
    cond =
      let
        env = fixtureCombination.env.${system};
      in
      lib.isDerivation env
      && (env.passthru.isFlakeSkillsEnv or false)
      && (map (m: m.name) env.passthru.flakeSkillsEnv) == [ "cx-gamma" ]
      && (lib.all (m: m.drv.passthru.isFlakeSkill or false) env.passthru.flakeSkillsEnv);
    msg =
      "combination-env: env.<sys> must be a derivation carrying "
      + "isFlakeSkillsEnv=true with members [cx-gamma], each drv a real "
      + "flake-skill (isFlakeSkill=true).";
  };

  # Consumable: the aggregate surface passes through verbatim — a single
  # `reconcile-combo` one-liner and the full app family (incl. `purge`).
  combination-consumable = mkEvalCheck {
    name = "combination-consumable";
    cond =
      let
        script = fixtureCombination.reconcileScript system;
        apps = fixtureCombination.apps.${system};
      in
      lib.hasInfix "/bin/reconcile-combo --scope=project" script
      && !(lib.hasInfix "\n" script)
      && builtins.all (a: apps ? ${a}) [
        "install"
        "uninstall"
        "preview"
        "reap"
        "purge"
        "reconcile"
      ];
    msg =
      "combination-consumable: reconcileScript must be a single "
      + "reconcile-combo --scope=project invocation and apps must expose the "
      + "full install/uninstall/preview/reap/purge/reconcile family.";
  };

  # ──────────────────────────────────────────────────────────────
  # darwinModules.default — forwarding shim into home-manager.
  # ──────────────────────────────────────────────────────────────

  # The darwin shim copies `services.agent-skill-flake.*` through to
  # `home-manager.users.<user>.programs.agent-skill-flake.*`. Asserts on the
  # propagated values, not on activation text — the home-manager
  # module's tests already cover that side.
  darwin-shim-forwards =
    let
      eval = nixpkgs.lib.evalModules {
        modules = [
          mockDarwinHM
          self.darwinModules.default
          {
            _module.args.pkgs = pkgs;
            services.agent-skill-flake = {
              enable = true;
              user = "alice";
              skills = [
                alphaPkg
                betaPkg
              ];
              autoDiscover = true;
              agent = "codex";
              scope = "custom";
              root = "/custom/skills";
            };
          }
        ];
      };

      forwarded = eval.config.home-manager.users.alice.programs.agent-skill-flake;
      importsList = eval.config.home-manager.users.alice.imports;
    in
    mkEvalCheck {
      name = "darwin-shim-forwards";
      cond =
        builtins.length importsList == 1
        && forwarded.enable == true
        && forwarded.autoDiscover == true
        && forwarded.agent == "codex"
        && forwarded.scope == "custom"
        && forwarded.root == "/custom/skills"
        && builtins.length forwarded.skills == 2;
      msg =
        "darwin-shim-forwards: forwarded values mismatch: "
        + builtins.toJSON {
          imports = builtins.length importsList;
          inherit (forwarded)
            enable
            autoDiscover
            agent
            scope
            root
            ;
          skills = builtins.length forwarded.skills;
        };
    };

  # `services.agent-skill-flake.user` defaults to `system.primaryUser` so
  # darwin consumers with that option set don't have to name the user
  # twice. Explicit overrides still win (covered by
  # darwin-shim-forwards).
  darwin-shim-defaults-user-from-system-primary =
    let
      eval = nixpkgs.lib.evalModules {
        modules = [
          mockDarwinHM
          self.darwinModules.default
          {
            _module.args.pkgs = pkgs;
            # No explicit `services.agent-skill-flake.user` — it must pick up
            # "bob" from system.primaryUser below.
            services.agent-skill-flake.enable = true;
            services.agent-skill-flake.scope = "personal";
            services.agent-skill-flake.skills = [ alphaPkg ];
            system.primaryUser = "bob";
          }
        ];
      };

      forwarded = eval.config.home-manager.users.bob.programs.agent-skill-flake;
    in
    mkEvalCheck {
      name = "darwin-shim-defaults-user";
      cond = forwarded.enable == true && builtins.length forwarded.skills == 1;
      msg = "darwin-shim-defaults-user: shim did not forward under " + "system.primaryUser 'bob'";
    };
}
