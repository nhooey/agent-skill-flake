{
  description = "flake-skills: lib.mkSkillFlake + lib.mkAllSkillsFlake for building Claude Code skill flakes";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # `self` plumbed in so lib can bake provenance (upstreamUrl, rev,
      # narHash, dirty) into each skill's sentinel without callers having to.
      flakeLib = import ./lib { inherit self; };

      # Internal helpers — used here to expose a top-level `reap` app that
      # works without any embedded skill set (pure cleanup tool).
      internal = import ./lib/internal.nix { inherit nixpkgs; };

      reapTopLevel =
        system:
        internal.mkReap system {
          appName = "flake-skills";
          inherit (flakeLib) provenance;
          profile = internal.resolveAgentProfile "claude-code";
        };

      # Single-skill fixture.
      fixture = flakeLib.mkSkillFlake {
        inherit nixpkgs;
        skillName = "example-skill";
        src = ./tests/example-skill;
      };

      # Multi-skill fixture: directory containing alpha/ + beta/ (and a
      # not-a-skill/ subdir + a top-level README.md to exercise discovery
      # filtering).
      fixtureAll = flakeLib.mkAllSkillsFlake {
        inherit nixpkgs;
        skillsDir = ./tests/example-skills-dir;
        name = "example-skills-dir";
      };

      # Single-skill fixture whose SKILL.md frontmatter `name:` diverges
      # from `skillName` — exercises build-time frontmatter normalization.
      fixtureRename = flakeLib.mkSkillFlake {
        inherit nixpkgs;
        skillName = "example-skill-renamed";
        src = ./tests/example-skill-rename;
      };

      # `extraFiles` fixtures. Same source skill rebuilt with four
      # different `extraFiles` settings so the bats tests can assert
      # positive, negative, no-match, and directory-skip behaviour
      # without paying for four distinct source trees.
      extraFilesSrc = ./tests/example-skill-extra-files;
      extraFilesSkillName = "example-skill-extra-files";
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
      # `extraFiles = [ "*" ]` against a source that has a top-level
      # directory (`companion-dir/`) which is NOT in `extraDirs`. The
      # `[ -f ]` guard inside the install loop must skip the directory
      # so only top-level regular files are shipped.
      fixtureExtraFilesDirSkip = flakeLib.mkSkillFlake {
        inherit nixpkgs;
        skillName = extraFilesSkillName;
        src = extraFilesSrc;
        extraFiles = [ "*" ];
      };

      # Single-skill fixture built with `agent = "codex"` so the
      # install scope tests can assert the codex profile's
      # `.codex/skills/` suffix is used (instead of `.claude/skills/`).
      fixtureCodex = flakeLib.mkSkillFlake {
        inherit nixpkgs;
        skillName = "example-skill";
        src = ./tests/example-skill;
        agent = "codex";
      };

      # Multi-skill fixture exercising a rich `renameFn`: the derived name
      # encodes the source owner, original skill name, short git rev, and
      # git last-modified date. `source` uses fixed values so the names
      # are deterministic under `nix flake check`:
      #   lastModifiedDate "20240424120000" → compact "20240424"
      #   rev[:7]                            → "0123456"
      # so alpha → "nhooey-alpha-0123456-20240424".
      fixtureAllRenamed = flakeLib.mkAllSkillsFlake {
        inherit nixpkgs;
        skillsDir = ./tests/example-skills-dir;
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
    in
    {
      lib = flakeLib;

      homeManagerModules.default = import ./home-manager-module.nix { inherit self nixpkgs; };

      darwinModules.default = import ./darwin-module.nix { inherit self nixpkgs; };

      apps = forAllSystems (system: {
        reap = {
          type = "app";
          program = "${reapTopLevel system}/bin/reap-flake-skills";
        };
      });

      checks = forAllSystems (
        system:
        import ./checks.nix {
          inherit
            self
            nixpkgs
            system
            fixture
            fixtureAll
            fixtureCodex
            fixtureRename
            fixtureAllRenamed
            fixtureExtraFiles
            fixtureExtraFilesOff
            fixtureExtraFilesNoMatch
            fixtureExtraFilesDirSkip
            ;
        }
      );
    };
}
