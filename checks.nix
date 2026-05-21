# Flake checks. Lifted out of flake.nix so the top-level outputs stay
# structural. Called once per system via forAllSystems.
{
  self,
  nixpkgs,
  system,
  fixture,
  fixtureAll,
  fixtureRename,
  fixtureAllRenamed,
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;

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
  uninstallSkillApp = fixture.apps.${system}.uninstall.program;

  # Multi-skill artifacts.
  allSkills = fixtureAll.packages.${system}.default;
  alphaPkg = fixtureAll.packages.${system}."skill-alpha";
  betaPkg = fixtureAll.packages.${system}."skill-beta";

  # Rename fixtures. `renamedSkill` proves frontmatter normalization
  # (its SKILL.md declares a divergent `name:`). `renamedAlphaPkg` proves
  # the `renameFn` formula + provenance: alpha discovered under
  # tests/example-skills-dir becomes `nhooey-alpha-0123456-20240424`.
  renamedSkill = fixtureRename.packages.${system}.default;
  renamedAlphaName = "nhooey-alpha-0123456-20240424";
  renamedAlphaPkg = fixtureAllRenamed.packages.${system}."skill-${renamedAlphaName}";
  installAllApp = fixtureAll.apps.${system}.install.program;
  uninstallAllApp = fixtureAll.apps.${system}.uninstall.program;
  previewAllApp = fixtureAll.apps.${system}.preview.program;
  reapAllApp = fixtureAll.apps.${system}.reap.program;
  reconcileAllApp = fixtureAll.apps.${system}.reconcile.program;

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
    env.SKILL_PKG_ROOT =
      "${fixture.packages.${system}."skill-example-skill"}/share/claude-skills/example-skill";
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
  # Rename + frontmatter-normalization checks.
  # ──────────────────────────────────────────────────────────────

  # mkSkill rewrites the installed SKILL.md so its frontmatter `name:`
  # equals the canonical name even when the source declared a different
  # one; store dir + sentinel agree; schemaVersion is 2 and the
  # pre-rename name is recorded as originalSkillName.
  example-skill-rename-normalizes-frontmatter = mkBatsCheck {
    name = "example-skill-rename-normalizes-frontmatter";
    extraInputs = [ pkgs.jq ];
    env.RENAME_SKILL_ROOT =
      "${renamedSkill}/share/claude-skills/example-skill-renamed";
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
            renameFn = _: "Bad_Name";
          };
        in
        builtins.seq bad.packages.${system}."skill-Bad_Name".drvPath true
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
            programs.flake-skills.enable = true;
            programs.flake-skills.skills = [
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
        && lib.hasInfix "/bin/reap-home-manager" data;
      msg = "home-manager-module-evaluates: activation data must invoke "
        + "reconcile + reap; got:\n${data}";
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
              programs.flake-skills.enable = true;
              programs.flake-skills.skills = skills;
              programs.flake-skills.autoDiscover = autoDiscover;
              home.packages = homePackages;
            }
          ];
        };

      # The activation data is `<reconcile>/bin/...\n<reap>/bin/...\n`;
      # the first line is the reconcile binary. Read its script content
      # back to see which skills were baked in.
      reconcileScript =
        ev:
        let
          data = ev.config.home.activation.flakeSkillsReconcile.data;
          firstLine = builtins.head (lib.splitString "\n" data);
        in
        builtins.readFile firstLine;

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
      msg = "home-manager-module-autodiscovers: autoDiscover gating wrong "
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
        skills = [ alphaPkg betaPkg ];
      };
    in
    mkEvalCheck {
      name = "mk-skills-env-passthru";
      cond =
        (env.passthru.isFlakeSkillsEnv or false)
        && (builtins.length env.passthru.flakeSkillsEnv == 2)
        && (lib.elem "alpha" (map (m: m.name) env.passthru.flakeSkillsEnv))
        && (lib.elem "beta" (map (m: m.name) env.passthru.flakeSkillsEnv))
        && (lib.all (m: m.drv ? passthru && m.drv.passthru.isFlakeSkill or false)
              env.passthru.flakeSkillsEnv);
      msg = "mk-skills-env-passthru: env must carry isFlakeSkillsEnv=true "
        + "and flakeSkillsEnv=[{name=alpha; ...} {name=beta; ...}] with "
        + "each member's drv carrying isFlakeSkill=true.";
    };

  # Passing a skills-env into `programs.flake-skills.skills` must expand
  # back into its member skills in the reconcile script — so a single
  # env entry installs N separate `~/.claude/skills/<name>/` trees, not
  # one nested env tree.
  home-manager-module-expands-skills-env =
    let
      env = self.lib.mkSkillsEnv {
        inherit pkgs;
        name = "skills-env-alpha-beta";
        skills = [ alphaPkg betaPkg ];
      };
      eval = nixpkgs.lib.evalModules {
        specialArgs.lib = mockHomeManagerLib;
        modules = [
          mockHomeManager
          self.homeManagerModules.default
          {
            _module.args.pkgs = pkgs;
            programs.flake-skills.enable = true;
            programs.flake-skills.skills = [ env ];
          }
        ];
      };
      data = eval.config.home.activation.flakeSkillsReconcile.data;
      reconcileBin = builtins.head (lib.splitString "\n" data);
      script = builtins.readFile reconcileBin;
    in
    mkEvalCheck {
      name = "home-manager-module-expands-skills-env";
      cond =
        lib.hasInfix ''"alpha:/nix/store/'' script
        && lib.hasInfix ''"beta:/nix/store/'' script;
      msg = "home-manager-module-expands-skills-env: reconcile script must "
        + "contain per-member `name:store-path` entries for both alpha and "
        + "beta after expansion, but at least one is missing.";
    };

  # ──────────────────────────────────────────────────────────────
  # darwinModules.default — forwarding shim into home-manager.
  # ──────────────────────────────────────────────────────────────

  # The darwin shim copies `services.flake-skills.*` through to
  # `home-manager.users.<user>.programs.flake-skills.*`. Asserts on the
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
            services.flake-skills = {
              enable = true;
              user = "alice";
              skills = [
                alphaPkg
                betaPkg
              ];
              autoDiscover = true;
              installRoot = "/custom/skills";
              envVarOverride = "CUSTOM_SKILLS_DIR";
            };
          }
        ];
      };

      forwarded = eval.config.home-manager.users.alice.programs.flake-skills;
      importsList = eval.config.home-manager.users.alice.imports;
    in
    mkEvalCheck {
      name = "darwin-shim-forwards";
      cond =
        builtins.length importsList == 1
        && forwarded.enable == true
        && forwarded.autoDiscover == true
        && forwarded.installRoot == "/custom/skills"
        && forwarded.envVarOverride == "CUSTOM_SKILLS_DIR"
        && builtins.length forwarded.skills == 2;
      msg = "darwin-shim-forwards: forwarded values mismatch: "
        + builtins.toJSON {
            imports = builtins.length importsList;
            inherit (forwarded) enable autoDiscover installRoot envVarOverride;
            skills = builtins.length forwarded.skills;
          };
    };

  # `services.flake-skills.user` defaults to `system.primaryUser` so
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
            # No explicit `services.flake-skills.user` — it must pick up
            # "bob" from system.primaryUser below.
            services.flake-skills.enable = true;
            services.flake-skills.skills = [ alphaPkg ];
            system.primaryUser = "bob";
          }
        ];
      };

      forwarded = eval.config.home-manager.users.bob.programs.flake-skills;
    in
    mkEvalCheck {
      name = "darwin-shim-defaults-user";
      cond = forwarded.enable == true && builtins.length forwarded.skills == 1;
      msg = "darwin-shim-defaults-user: shim did not forward under "
        + "system.primaryUser 'bob'";
    };
}
