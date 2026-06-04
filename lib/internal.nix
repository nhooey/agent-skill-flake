{ nixpkgs }:
let
  inherit (nixpkgs) lib;

  # Single source of truth for the `systems` fan-out every builder needs
  # (packages/apps/devShells). `forAllSystems systems (system: …)` →
  # `{ <system> = …; }`.
  forAllSystems = systems: f: lib.genAttrs systems (system: f system);

  agentProfiles = import ./agent-profiles.nix;

  # Shared awk that normalizes installed SKILL.md frontmatter `name:`.
  # Used by both `mkSkill` (below) and `withNamePrefix`.
  normalizeFrontmatterScript = import ./normalize-frontmatter.nix;

  # Look up an agent profile by name; fail eval with the list of known
  # agents if the name isn't a known profile.
  resolveAgentProfile =
    agent:
    if agentProfiles ? ${agent} then
      agentProfiles.${agent}
    else
      throw (
        "flake-skills: unknown agent profile ${builtins.toJSON agent}. "
        + "Known agents: "
        + lib.concatStringsSep ", " (builtins.attrNames agentProfiles)
        + ". Add a new profile to lib/agent-profiles.nix to extend this set."
      );

  # ── Shared validators ────────────────────────────────────────────────
  # Name/prefix rules live in lib/skill-name.nix (lib-only) so the
  # consumer-side `withNamePrefix` can share them; re-exported below.
  inherit (import ./skill-name.nix { inherit lib; })
    isValidSkillName
    assertValidSkillName
    validateNamePrefix
    validateNamespaceSegment
    assertUniqueSkillNames
    ;

  # Category prefix on every per-skill package attribute key, before the
  # owner namespace segment and the skill name: `<packagePrefix><owner>-<name>`.
  # The single default every builder resolves against (they take
  # `packagePrefix ? null` and fall back here) so the convention lives in
  # one place. Aggregates/envs use the plural `agent-skills-` form.
  defaultPackagePrefix = "agent-skill-";

  # ── Sentinel ─────────────────────────────────────────────────────────
  # The `.flake-skills-managed.json` record written into every installed
  # skill. Single source of truth for the schema/field set; `mkSkill`
  # builds it at eval, and `withNamePrefix` rewrites only `skillName` on an
  # already-built file via jq (see lib/with-name-prefix.nix) — keep the two
  # in sync through this definition.
  mkSentinel =
    {
      name,
      originalSkillName,
      version,
      provenance,
    }:
    builtins.toJSON {
      schemaVersion = 2;
      managedBy = provenance.upstreamUrl;
      managedByRev = provenance.rev;
      managedByDirty = provenance.dirty;
      managedByNarHash = provenance.narHash;
      skillName = name;
      inherit originalSkillName version;
    };

  # Filter an attrset's keys to those a skill package set exposes under
  # `prefix` — drops `default` / `<name>-all` aggregate keys. Used wherever
  # a source's `packages.<system>` is sifted for its per-skill entries.
  skillKeysWithPrefix =
    attrs: prefix: builtins.filter (lib.hasPrefix prefix) (builtins.attrNames attrs);

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
      # Leading `<scheme>:` before any `/`, lowercased (github, gitlab,
      # git+ssh, git+file, file, path, https, …). null when there is none.
      schemeMatch = builtins.match "([a-zA-Z][a-zA-Z0-9+.-]*):.*" noGit;
      scheme = if schemeMatch == null then null else lib.toLower (builtins.head schemeMatch);
      # A `file`/`path` ref (incl. `git+file`), or a bare local filesystem
      # path / store path, has no hosting-owner concept — its "owner" must
      # resolve to null so `namespaceFn`'s default fails loud rather than
      # fabricating a segment from a directory name.
      isLocal =
        (scheme != null && (lib.hasInfix "file" scheme || scheme == "path"))
        || (scheme == null && (lib.hasPrefix "/" noGit || lib.hasPrefix "." noGit));
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
    if !isLocal && n >= 2 then
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
    {
      name,
      source ? null,
      toolingProvenance,
    }:
    let
      tSlug = parseRepoSlug toolingProvenance.upstreamUrl;
      # `x or y`-the-keyword only works on attr selection, so a plain
      # null-coalescing helper for the "use source's value, else derive".
      orElse = x: y: if x == null then y else x;
      get = a: if source == null then null else (source.${a} or null);
      srcRevRaw = get "rev";
      srcDirty =
        if source == null then
          null
        else
          (source.dirty or (srcRevRaw != null && lib.hasSuffix "-dirty" srcRevRaw));
      srcRev = if srcRevRaw == null then null else lib.removeSuffix "-dirty" srcRevRaw;
      srcShort = if srcRev == null then null else orElse (get "shortRev") (builtins.substring 0 7 srcRev);
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
          if srcSlug.owner != null && srcSlug.repo != null then
            "github:${srcSlug.owner}/${srcSlug.repo}"
          else
            null
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

  # Apply the rename formula to one skill. Returns the post-rename
  # `effective` name plus the `original` (pre-rename) name kept for the
  # sentinel's `originalSkillName`. Centralizes the `renameFn
  # (mkRenameContext {...})` call shared by the single- and multi-skill
  # builders so the context shape can't drift between them.
  applyRename =
    {
      name,
      source ? null,
      provenance,
      renameFn,
    }:
    {
      effective = renameFn (mkRenameContext {
        inherit name source;
        toolingProvenance = provenance;
      });
      original = name;
    };

  # Compose a package attribute key from the category prefix, the resolved
  # owner namespace segment, and the effective skill name. The single
  # source of truth for the `<packagePrefix><namespace>-<name>` key shape;
  # an empty namespace yields `<packagePrefix><name>`.
  mkPackageKey =
    {
      packagePrefix,
      namespace,
      name,
    }:
    if namespace == "" then "${packagePrefix}${name}" else "${packagePrefix}${namespace}-${name}";

  # Resolve the owner namespace segment for a package key from a
  # `namespaceFn` (default `ctx: ctx.source.owner`) and a rename context.
  # Fail loud, never invent a name: a null result (no/local/ownerless
  # source) throws and lists the three escapes; "" passes through as a
  # deliberate opt-out; a non-empty segment is validated.
  resolveNamespace =
    { namespaceFn, ctx }:
    let
      segment = namespaceFn ctx;
    in
    if segment == null then
      throw ''
        flake-skills: could not resolve a package-key namespace for skill ${builtins.toJSON ctx.name}.
        The namespace defaults to the source owner (`ctx.source.owner`), which is null here — the
        source is unset, local (file:/path:), or otherwise ownerless. Choose one:
          • pass `source` with a derivable owner, e.g. { url = "github:owner/repo"; } or { owner = "owner"; };
          • set `namespaceFn = _: "your-handle"` to name the package keys explicitly; or
          • set `namespaceFn = _: ""` to ship un-namespaced keys on purpose.
      ''
    else
      validateNamespaceSegment segment;

  # One-stop naming resolution for a single skill, shared by the single-
  # and multi-skill builders so the rename context, namespace resolution,
  # and key composition can't drift between them. Returns the effective
  # (installed) name, the pre-rename original, the resolved namespace, and
  # the package attribute key.
  resolveSkillNaming =
    {
      name,
      source ? null,
      provenance,
      renameFn,
      namespaceFn,
      packagePrefix,
    }:
    let
      ctx = mkRenameContext {
        inherit name source;
        toolingProvenance = provenance;
      };
      effective = renameFn ctx;
      namespace = resolveNamespace { inherit namespaceFn ctx; };
    in
    {
      inherit effective namespace;
      original = name;
      key = mkPackageKey {
        inherit packagePrefix namespace;
        name = effective;
      };
    };

  mkSkill =
    system:
    {
      name,
      src,
      version ? "0.1.0",
      description ? "Claude Code skill: ${name}",
      # Additional top-level directories to ship alongside the standard
      # SKILL.md / references / scripts trio. Use for upstream skills whose
      # SKILL.md references content in non-standard subdirs (e.g.
      # anthropics/skills' skill-creator references `agents/`, `assets/`,
      # `eval-viewer/`). Each entry is a bare directory name relative to
      # the skill source root; missing dirs are silently ignored, same as
      # references/scripts.
      extraDirs ? [ ],
      # Additional top-level files to ship at the install root. Each entry
      # is a shell glob evaluated in the skill source root at install time
      # (nullglob: no-match patterns are silently dropped, same posture as
      # `extraDirs`). Matches that resolve to directories are skipped — use
      # `extraDirs` for those. Use for upstream skills whose SKILL.md
      # cross-references loose flat files at the top level (e.g.
      # obra/superpowers' `visual-companion.md`, `code-reviewer.md`),
      # which the standard SKILL.md + references/ + scripts/ whitelist
      # would otherwise drop.
      extraFiles ? [ ],
      # The skill's identity *before* any rename — the directory name as
      # discovered (multi-skill) or the caller's `skillName` (single).
      # Recorded in the sentinel as provenance so a remapped install can
      # still be traced back to what it was called upstream. Defaults to
      # `name` (no rename).
      originalSkillName ? name,
      # Provenance from lib/default.nix: which flake-skills lineage built
      # this, what rev / dirty state, and the source narHash for
      # differentiation across dirty builds. Written verbatim into the
      # `.flake-skills-managed.json` sentinel so reconcile/reap can decide
      # what's "ours" without needing flake metadata at runtime.
      provenance,
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};

      # See lib/normalize-frontmatter.nix for the rename contract; the
      # script is shared with `withNamePrefix` so both rewrite frontmatter
      # `name:` identically. Run below via `awk -v newname=… -f`.
      normalizeFrontmatterAwk = pkgs.writeText "normalize-skill-frontmatter.awk" normalizeFrontmatterScript;

      sentinel = mkSentinel {
        inherit
          name
          originalSkillName
          version
          provenance
          ;
      };
    in
    assert assertValidSkillName name "skill name";
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
        # extraFiles runs first so the canonical files written below
        # (awk-normalized SKILL.md, sentinel) overwrite any same-named
        # entry copied from the source root — a glob like
        # `extraFiles = [ "*.md" ]` legitimately matches SKILL.md, and
        # the awk-normalized frontmatter must win.
        #
        # nullglob makes a non-matching pattern expand to nothing instead
        # of being copied as a literal; the [ -f ] guard skips directory
        # matches so `extraFiles = [ "*" ]` ships only top-level regular
        # files (directories already have `extraDirs`).
        shopt -s nullglob
        for pat in ${lib.concatMapStringsSep " " lib.escapeShellArg extraFiles}; do
          for f in $pat; do
            [ -f "$f" ] || continue
            install -Dm644 "$f" "$out/share/claude-skills/${name}/$(basename "$f")"
          done
        done
        shopt -u nullglob
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
    map (n: {
      name = n;
      src = skillsDir + "/${n}";
    }) skillNames;

  # Bash-array body: one `"name:store_path"` line per skill, indented.
  skillsArrayBody =
    skills:
    if skills == [ ] then "" else lib.concatMapStringsSep "\n" (s: ''"${s.name}:${s.drv}"'') skills;

  # Shared Nix-side prelude. Sets `app_name`, `personal_suffix`,
  # `project_suffix` and sources scope.bash so `parse_scope_args` is
  # available to the per-app bash that follows.
  scopePrelude =
    { appName, profile }:
    ''
      app_name="${appName}"
      personal_suffix='${profile.personalSuffix}'
      project_suffix='${profile.projectSuffix}'

      source ${./bash/scope.bash}
    '';

  # Factory behind every installer/reap/purge/reconcile/uninstall/preview app.
  # The `<verb>` apps share one shape — `writeShellApplication` whose
  # `text` is `scopePrelude` + a few env-var assignments + sourced helper
  # libraries + an optional `skills_list` array + the verb's bash script.
  # Only four things vary per verb, all passed in: `runtimeInputs`, the
  # extra env-var lines (`extraEnv`), which `./bash/*.bash` helpers get
  # sourced (`sourceModules`), and whether a `skills_list` array is emitted
  # (`skills` non-null). The base `excludeShellChecks` are shared; an app
  # that defines a var consumed only by a sourced helper adds `SC2034`.
  mkShellApp =
    system:
    {
      verb,
      appName,
      profile,
      runtimeInputs,
      extraEnv ? "",
      sourceModules ? [ ],
      skills ? null,
      extraExcludeShellChecks ? [ ],
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      fullAppName = "${verb}-${appName}";
      sourceLines =
        if sourceModules == [ ] then
          ""
        else
          lib.concatMapStringsSep "\n" (m: "source ${m}") sourceModules + "\n";
      skillsArray =
        if skills == null then "" else "declare -a skills_list=(\n${skillsArrayBody skills}\n)\n";
    in
    pkgs.writeShellApplication {
      name = fullAppName;
      inherit runtimeInputs;
      # shellcheck can't follow `source <store-path>` because the helper
      # libraries aren't declared as inputs in the bash sense.
      excludeShellChecks = [
        "SC1091" # source <store-path> not followable
        "SC2154"
        # vars (target_root, gcroots_dir, scope_remaining_args)
        # are assigned by scope.bash, which shellcheck can't follow
        "SC2016"
        # `nn` inside single-quoted printf strings is literal
        # backtick markup, not an attempt to expand a subshell
      ]
      ++ extraExcludeShellChecks;
      # scopePrelude ends with a trailing newline; each piece below is
      # newline-terminated (or empty) so no two tokens glue together.
      text =
        scopePrelude {
          appName = fullAppName;
          inherit profile;
        }
        + extraEnv
        + "\n"
        + sourceLines
        + skillsArray
        + builtins.readFile ./bash/${verb}.sh;
    };

  mkInstaller =
    system:
    {
      appName,
      skills,
      profile,
    }:
    mkShellApp system {
      verb = "install";
      inherit appName profile skills;
      runtimeInputs = with nixpkgs.legacyPackages.${system}; [
        coreutils
        git
        jq
        nix
      ];
      extraEnv = "owner_app='${appName}'";
      sourceModules = [ ./bash/lock.bash ];
      # owner_app is consumed only by the sourced lock.bash (lock_upsert),
      # which shellcheck can't follow.
      extraExcludeShellChecks = [ "SC2034" ];
    };

  # Reap + purge are the two lineage-keyed sweeps. Both carry no skill set
  # (so they run transiently off the bare upstream flake) and share the
  # walk in ./bash/lineage-sweep.bash, differing only in the predicate
  # their <verb>.sh defines. Reap removes only GC-broken entries (safe
  # maintenance); purge removes every lineage entry, live or broken (the
  # teardown escape hatch). `sweep_label`/`sweep_verb`/`dry_run` are set in
  # the verb script and consumed only inside the sourced sweep helper, so
  # both opt into SC2034 the same way the installer does for `owner_app`.
  mkLineageSweep =
    verb: system:
    {
      appName,
      provenance,
      profile,
    }:
    mkShellApp system {
      inherit verb appName profile;
      runtimeInputs = with nixpkgs.legacyPackages.${system}; [
        coreutils
        git
        jq
      ];
      extraEnv = "upstream_url='${provenance.upstreamUrl}'";
      sourceModules = [
        ./bash/ownership.bash
        ./bash/lock.bash
        ./bash/lineage-sweep.bash
      ];
      extraExcludeShellChecks = [ "SC2034" ];
    };

  mkReap = mkLineageSweep "reap";
  mkPurge = mkLineageSweep "purge";

  mkReconcile =
    system:
    {
      appName,
      skills,
      provenance,
      profile,
    }:
    mkShellApp system {
      verb = "reconcile";
      inherit appName profile skills;
      runtimeInputs = with nixpkgs.legacyPackages.${system}; [
        coreutils
        git
        jq
      ];
      extraEnv = ''
        upstream_url='${provenance.upstreamUrl}'
        owner_app='${appName}'
      '';
      sourceModules = [
        ./bash/ownership.bash
        ./bash/lock.bash
      ];
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
    {
      appName,
      provenance,
      profile,
      defaultSkillName ? "",
    }:
    mkShellApp system {
      verb = "uninstall";
      inherit appName profile;
      runtimeInputs = with nixpkgs.legacyPackages.${system}; [
        coreutils
        git
        jq
      ];
      extraEnv = ''
        upstream_url='${provenance.upstreamUrl}'
        default_skill='${defaultSkillName}'
      '';
      sourceModules = [
        ./bash/ownership.bash
        ./bash/lock.bash
      ];
    };

  mkPreview =
    system:
    {
      appName,
      displayName,
      skills,
      profile,
    }:
    mkShellApp system {
      verb = "preview";
      inherit appName profile skills;
      runtimeInputs = with nixpkgs.legacyPackages.${system}; [
        coreutils
        findutils
        git
      ];
      extraEnv = "display_name='${displayName}'";
    };

  # Build a flake `apps.<system>` attrset from a verb→derivation map. Each
  # `programs.<verb>` is an already-system-applied app derivation whose binary
  # is `<verb>-<name>`; the entry becomes `{ type = "app"; program = …; }`.
  # `default ? false` aliases `default` to the preview program (the bare
  # `nix run` entrypoint), matching the single-skill / aggregate builders.
  mkAppSuite =
    {
      name,
      programs,
      default ? false,
    }:
    let
      app = verb: drv: {
        type = "app";
        program = "${drv}/bin/${verb}-${name}";
      };
    in
    lib.mapAttrs app programs
    // lib.optionalAttrs default { default = app "preview" programs.preview; };
in
{
  inherit
    forAllSystems
    mkAppSuite
    mkSkill
    mkRenameContext
    applyRename
    resolveSkillNaming
    resolveNamespace
    mkPackageKey
    assertUniqueSkillNames
    defaultPackagePrefix
    discoverSkills
    mkInstaller
    mkUninstall
    mkPreview
    mkReap
    mkPurge
    mkReconcile
    resolveAgentProfile
    agentProfiles
    skillKeysWithPrefix
    validateNamePrefix
    validateNamespaceSegment
    assertValidSkillName
    isValidSkillName
    ;
}
