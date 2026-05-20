{ nixpkgs }:
let
  inherit (nixpkgs) lib;

  # ── Rename-context plumbing ──────────────────────────────────────────
  # The rename formula (`renameFn`) is handed a context attrset, not a
  # bare string, so a derived name can encode where the skill came from
  # (owner/repo), which revision, and when it was last touched in git.

  # Nix flakes already expose `self.lastModifiedDate` as a UTC
  # "%Y%m%d%H%M%S" string, and nixpkgs' own lib/flake-version-info.nix
  # derives dates by slicing exactly that. So the date the rename
  # formula wants is a substring op, not epoch arithmetic — no
  # civil-from-days math, no IFD, no coreutils `date`.
  sliceNixDate =
    s:
    if s == null then
      {
        date = null;
        compact = null;
      }
    else
      let
        sub = builtins.substring;
      in
      {
        compact = sub 0 8 s; # "YYYYMMDD"
        date = "${sub 0 4 s}-${sub 4 2 s}-${sub 6 2 s}"; # "YYYY-MM-DD"
      };

  # Host-agnostic `owner` / `repo` extraction from any git URL shape:
  # `scheme://[user@]host[:port]/owner/repo[.git]`, scp-like
  # `git@host:owner/repo.git`, flake shorthand `type:owner/repo`, and
  # bare `owner/repo`. Returns nulls rather than throwing so a formula
  # that doesn't reference owner/repo still works for any source.
  #
  # `builtins.parseFlakeRef` is deliberately NOT used: it throws an
  # *uncatchable* eval error on scp-like URLs (`tryEval` does not
  # rescue it) and mis-types plain `https://` / bare-slug refs. There
  # is no host-agnostic owner/repo concept anyway (GitLab subgroups,
  # Gitea, self-hosted) so for >2 path segments this takes the last
  # two — best effort, documented as such.
  parseRepoSlug =
    url:
    let
      noGit = lib.removeSuffix ".git" (lib.removeSuffix "/" url);
      path =
        if lib.hasInfix "://" noGit then
        # scheme://[user@]host[:port]/owner/repo → drop scheme,
        # optional userinfo, and the host[:port] segment.
          let
            afterScheme = lib.last (lib.splitString "://" noGit);
            afterUser = lib.last (lib.splitString "@" afterScheme);
          in
          lib.concatStringsSep "/" (lib.drop 1 (lib.splitString "/" afterUser))
        else if lib.hasInfix ":" noGit then
        # scp-like `git@host:owner/repo` or shorthand `type:owner/repo`
          lib.last (lib.splitString ":" noGit)
        else
          noGit;
      parts = builtins.filter (s: s != "") (lib.splitString "/" path);
      n = builtins.length parts;
    in
    if n >= 2 then
      {
        owner = builtins.elemAt parts (n - 2);
        repo = builtins.elemAt parts (n - 1);
      }
    else
      {
        owner = null;
        repo = null;
      };

  # Assemble the attrset passed to `renameFn`. `source` is the *skill's*
  # origin repo (the consumer fills it from their own flake `self` +
  # owner/repo); `toolingProvenance` is the flake-skills lineage that
  # built the tooling (already threaded everywhere as `provenance`).
  # Kept distinct on purpose: in a marketplace flake the skills and the
  # build tooling routinely live in different repos.
  mkRenameContext =
    { name
    , source ? null
    , toolingProvenance
    ,
    }:
    let
      tSlug = parseRepoSlug toolingProvenance.upstreamUrl;
      # `x or y`-the-keyword only works on attr selection, so a plain
      # null-coalescing helper for the "use source's value, else derive".
      orElse = x: y: if x == null then y else x;
      get = a: if source == null then null else (source.${a} or null);
      srcRevRaw = get "rev";
      srcDirty =
        if source == null then null
        else (source.dirty or (srcRevRaw != null && lib.hasSuffix "-dirty" srcRevRaw));
      srcRev =
        if srcRevRaw == null then null
        else lib.removeSuffix "-dirty" srcRevRaw;
      srcShort =
        if srcRev == null then null
        else orElse (get "shortRev") (builtins.substring 0 7 srcRev);
      srcSlug =
        if source == null then
          {
            owner = null;
            repo = null;
          }
        else if (source ? owner) || (source ? repo) then
          {
            owner = source.owner or null;
            repo = source.repo or null;
          }
        else if source ? url then
          parseRepoSlug source.url
        else
          {
            owner = null;
            repo = null;
          };
      srcLM = get "lastModified";
      lmd = sliceNixDate (get "lastModifiedDate");
    in
    {
      inherit name;
      source = {
        inherit (srcSlug) owner repo;
        url = orElse (get "url") (
          if srcSlug.owner != null && srcSlug.repo != null then "github:${srcSlug.owner}/${srcSlug.repo}"
          else null
        );
        rev = srcRev;
        shortRev = srcShort;
        dirty = srcDirty;
        narHash = get "narHash";
        lastModified = srcLM;
        lastModifiedDate = lmd.date;
        lastModifiedCompact = lmd.compact;
      };
      tooling = {
        inherit (tSlug) owner repo;
        url = toolingProvenance.upstreamUrl;
        rev = toolingProvenance.rev;
        shortRev = builtins.substring 0 7 toolingProvenance.rev;
        dirty = toolingProvenance.dirty;
        narHash = toolingProvenance.narHash;
      };
    };

  mkSkill =
    system:
    { name
    , src
    , version ? "0.1.0"
    , description ? "Claude Code skill: ${name}"
    , # Additional top-level directories to ship alongside the standard
      # SKILL.md / references / scripts trio. Use for upstream skills whose
      # SKILL.md references content in non-standard subdirs (e.g.
      # anthropics/skills' skill-creator references `agents/`, `assets/`,
      # `eval-viewer/`). Each entry is a bare directory name relative to
      # the skill source root; missing dirs are silently ignored, same as
      # references/scripts.
      extraDirs ? [ ]
    , # The skill's identity *before* any rename — the directory name as
      # discovered (multi-skill) or the caller's `skillName` (single).
      # Recorded in the sentinel as provenance so a remapped install can
      # still be traced back to what it was called upstream. Defaults to
      # `name` (no rename).
      originalSkillName ? name
    , # Provenance from lib/default.nix: which flake-skills lineage built
      # this, what rev / dirty state, and the source narHash for
      # differentiation across dirty builds. Written verbatim into the
      # `.flake-skills-managed.json` sentinel so reconcile/reap can decide
      # what's "ours" without needing flake metadata at runtime.
      provenance
    ,
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};

      # Claude Code's hard constraint on the effective skill name (the
      # `name:` frontmatter / directory name): lowercase letters, digits,
      # hyphens, ≤64 chars. `builtins.match` is whole-string-anchored.
      # Assert at eval so a bad `skillName` / `renameFn` fails `nix flake
      # check` with a clear message instead of silently producing a skill
      # Claude Code refuses to load.
      nameOk = builtins.match "[a-z0-9-]{1,64}" name != null;

      # awk pass that normalizes the *installed* SKILL.md so its
      # top-level frontmatter `name:` equals the canonical `name`. This
      # is the half a directory rename can't do alone: Claude Code reads
      # the frontmatter `name:` in preference to the directory, so a
      # rename that didn't rewrite it would silently keep the old
      # identity. Only the first `---`-fenced block is touched, and only
      # a column-0 `name:` key (an indented `name:` under e.g.
      # `metadata:` is correctly left alone); if the block has no `name:`
      # one is injected; a file with no frontmatter gets one synthesized.
      normalizeFrontmatterAwk = pkgs.writeText "normalize-skill-frontmatter.awk" ''
        BEGIN { state = 0; seen = 0 }
        NR == 1 && $0 != "---" {
          print "---"
          print "name: " newname
          print "---"
          print ""
          print
          state = 2
          next
        }
        NR == 1 {
          print
          state = 1
          next
        }
        state == 1 && $0 == "---" {
          if (seen == 0) print "name: " newname
          print
          state = 2
          next
        }
        state == 1 && /^name[[:blank:]]*:/ {
          print "name: " newname
          seen = 1
          next
        }
        { print }
      '';

      sentinel = builtins.toJSON {
        schemaVersion = 2;
        managedBy = provenance.upstreamUrl;
        managedByRev = provenance.rev;
        managedByDirty = provenance.dirty;
        managedByNarHash = provenance.narHash;
        skillName = name;
        inherit originalSkillName version;
      };
    in
    assert lib.assertMsg nameOk
      (
        "flake-skills: skill name ${builtins.toJSON name} is invalid. "
        + "Claude Code skill names must match ^[a-z0-9-]{1,64}$ "
        + "(lowercase letters, digits, hyphens; ≤64 chars). "
        + "Fix the skillName / renameFn that produced it."
      );
    pkgs.stdenvNoCC.mkDerivation {
      pname = "claude-skill-${name}";
      inherit version src;
      dontBuild = true;
      # Pass the JSON via env so we don't have to escape it inside the bash
      # heredoc; bash will see it as a single literal string.
      passAsFile = [ "sentinel" ];
      inherit sentinel;
      # Discovery markers consumed by darwinModules.default: lets the
      # activation hook filter `environment.systemPackages` for skills and
      # extract the bare skill name without parsing `pname`.
      passthru = {
        isFlakeSkill = true;
        flakeSkillName = name;
      };
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/share/claude-skills/${name}"
        awk -v newname=${lib.escapeShellArg name} \
          -f ${normalizeFrontmatterAwk} \
          SKILL.md > "$out/share/claude-skills/${name}/SKILL.md"
        chmod 644 "$out/share/claude-skills/${name}/SKILL.md"
        for d in references scripts ${lib.concatMapStringsSep " " lib.escapeShellArg extraDirs}; do
          if [ -d "$d" ]; then
            mkdir -p "$out/share/claude-skills/${name}/$d"
            cp -r "$d/." "$out/share/claude-skills/${name}/$d/"
          fi
        done
        install -Dm644 "$sentinelPath" \
          "$out/share/claude-skills/${name}/.flake-skills-managed.json"
        runHook postInstall
      '';
      meta = with pkgs.lib; {
        inherit description;
        license = licenses.asl20;
        platforms = platforms.unix;
      };
    };

  # A subdirectory of `skillsDir` is a "skill" iff it contains a SKILL.md.
  # Returns a sorted list of { name; src; } records.
  discoverSkills =
    skillsDir:
    let
      entries = builtins.readDir skillsDir;
      isDir = n: entries.${n} == "directory";
      hasSkillMd = n: builtins.pathExists (skillsDir + "/${n}/SKILL.md");
      dirNames = builtins.attrNames (lib.filterAttrs (n: _: isDir n) entries);
      skillNames = builtins.filter hasSkillMd dirNames;
    in
    map
      (n: {
        name = n;
        src = skillsDir + "/${n}";
      })
      skillNames;

  # Bash-array body: one `"name:store_path"` line per skill, indented.
  skillsArrayBody =
    skills:
    if skills == [ ] then
      ""
    else
      lib.concatMapStringsSep "\n" (s: ''  "${s.name}:${s.drv}"'') skills;

  mkInstaller =
    system:
    { appName
    , skills
    , installRoot
    , envVarOverride
    ,
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    pkgs.writeShellApplication {
      name = "install-${appName}";
      runtimeInputs = with pkgs; [
        coreutils
        jq
        nix
      ];
      # shellcheck can't follow `source <store-path>` because the helper
      # libraries aren't declared as inputs in the bash sense.
      excludeShellChecks = [ "SC1091" ];
      text =
        ''
          app_name="install-${appName}"
          env_var_name="${envVarOverride}"
          install_root_default="${installRoot}"
          target_root=''${${envVarOverride}:-${installRoot}}

          source ${./bash/lock.bash}

          declare -a skills_list=(
          ${skillsArrayBody skills}
          )
        ''
        + builtins.readFile ./bash/install.sh;
    };

  mkReap =
    system:
    { appName
    , provenance
    , installRoot
    , envVarOverride
    ,
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    pkgs.writeShellApplication {
      name = "reap-${appName}";
      runtimeInputs = with pkgs; [
        coreutils
        jq
      ];
      # shellcheck can't follow `source <store-path>` because the helper
      # libraries aren't declared as inputs in the bash sense.
      excludeShellChecks = [ "SC1091" ];
      text =
        ''
          target_root=''${${envVarOverride}:-${installRoot}}
          gcroots_dir=''${NIX_GCROOTS_DIR:-/nix/var/nix/gcroots/per-user/$USER}
          upstream_url='${provenance.upstreamUrl}'

          source ${./bash/ownership.bash}
          source ${./bash/lock.bash}
        ''
        + builtins.readFile ./bash/reap.sh;
    };

  mkReconcile =
    system:
    { appName
    , skills
    , provenance
    , installRoot
    , envVarOverride
    ,
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    pkgs.writeShellApplication {
      name = "reconcile-${appName}";
      runtimeInputs = with pkgs; [
        coreutils
        jq
      ];
      # shellcheck can't follow `source <store-path>` because the helper
      # libraries aren't declared as inputs in the bash sense.
      excludeShellChecks = [ "SC1091" ];
      text =
        ''
          target_root=''${${envVarOverride}:-${installRoot}}
          gcroots_dir=''${NIX_GCROOTS_DIR:-/nix/var/nix/gcroots/per-user/$USER}
          upstream_url='${provenance.upstreamUrl}'

          source ${./bash/ownership.bash}
          source ${./bash/lock.bash}

          declare -a skills_list=(
          ${skillsArrayBody skills}
          )
        ''
        + builtins.readFile ./bash/reconcile.sh;
    };

  # Uninstall: undo a prior install for one or more named skills. Removes
  # the user-facing symlink, the per-user GC root, and the lock entry — the
  # three things `mkInstaller` writes. Refuses to touch entries it can't
  # confidently identify as managed by this lineage (sentinel `managedBy`
  # match, or naming-convention fallback for broken-symlink case), so a
  # user's hand-rolled `~/.claude/skills/foo` directory is safe.
  #
  # `defaultSkillName` is set by the single-skill wrapper (mkSkillFlake) so
  # `nix run .#uninstall` (no args) does the obvious thing for repos with
  # exactly one skill. Multi-skill flakes leave it empty and require the
  # user to name what to remove.
  mkUninstall =
    system:
    { appName
    , provenance
    , installRoot
    , envVarOverride
    , defaultSkillName ? ""
    ,
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    pkgs.writeShellApplication {
      name = "uninstall-${appName}";
      runtimeInputs = with pkgs; [
        coreutils
        jq
      ];
      # shellcheck can't follow `source <store-path>` because the helper
      # libraries aren't declared as inputs in the bash sense.
      excludeShellChecks = [ "SC1091" ];
      text =
        ''
          app_name="uninstall-${appName}"
          env_var_name="${envVarOverride}"
          install_root_default="${installRoot}"
          target_root=''${${envVarOverride}:-${installRoot}}
          gcroots_dir=''${NIX_GCROOTS_DIR:-/nix/var/nix/gcroots/per-user/$USER}
          upstream_url='${provenance.upstreamUrl}'
          default_skill='${defaultSkillName}'

          source ${./bash/ownership.bash}
          source ${./bash/lock.bash}
        ''
        + builtins.readFile ./bash/uninstall.sh;
    };

  mkPreview =
    system:
    { appName
    , displayName
    , skills
    , installRoot
    , envVarOverride
    ,
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    pkgs.writeShellApplication {
      name = "preview-${appName}";
      runtimeInputs = with pkgs; [
        coreutils
        findutils
      ];
      text =
        ''
          display_name='${displayName}'
          env_var_name="${envVarOverride}"
          target_root=''${${envVarOverride}:-${installRoot}}

          declare -a skills_list=(
          ${skillsArrayBody skills}
          )
        ''
        + builtins.readFile ./bash/preview.sh;
    };
in
{
  inherit
    mkSkill
    mkRenameContext
    discoverSkills
    mkInstaller
    mkUninstall
    mkPreview
    mkReap
    mkReconcile
    ;
}
