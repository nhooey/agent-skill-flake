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
      text = ''
        target_root=''${${envVarOverride}:-${installRoot}}

        ${lockBashHelpers}

        mode=symlink
        for arg in "$@"; do
          case "$arg" in
            --profile) mode=profile ;;
            -h|--help)
              cat <<EOF
        Usage: install-${appName} [--profile]

        Default (symlink mode):
          For each skill, creates a symlink at \$target_root/<skill> pointing
          to its content under the Nix store, and registers a per-user GC root
          so the store path is protected from \`nix-store --gc\`.

        --profile:
          Installs each skill into your Nix profile (\`nix profile install\`),
          then symlinks \$target_root/<skill> into
          ~/.nix-profile/share/claude-skills/. Skills then appear in
          \`nix profile list\` and support \`nix profile upgrade\` / rollback.

        Environment:
          ${envVarOverride}    override the install root (default: ${installRoot})
          NIX_GCROOTS_DIR    override the GC-roots dir (default: per-user dir)

        Currently installed target root: $target_root
        EOF
              exit 0
              ;;
            *)
              echo "Unknown argument: $arg" >&2
              echo "Try '--help'." >&2
              exit 2
              ;;
          esac
        done

        declare -a skills_list=(
        ${skillsArrayBody skills}
        )

        mkdir -p "$target_root"

        case "$mode" in
          symlink)
            gcroots_dir=''${NIX_GCROOTS_DIR:-/nix/var/nix/gcroots/per-user/$USER}
            gcroots_ok=1
            if ! mkdir -p "$gcroots_dir" 2>/dev/null; then
              gcroots_ok=0
              printf 'WARNING: could not create %s; store paths may be GC-eligible\n' "$gcroots_dir" >&2
            fi
            for entry in "''${skills_list[@]}"; do
              skill_name=''${entry%%:*}
              store_path=''${entry#*:}
              skill_subpath="$store_path/share/claude-skills/$skill_name"
              target="$target_root/$skill_name"
              rm -rf "$target"
              ln -sfn "$skill_subpath" "$target"
              printf 'installed (symlink): %s -> %s\n' "$target" "$skill_subpath"
              if [ "$gcroots_ok" = "1" ]; then
                if ln -sfn "$store_path" "$gcroots_dir/claude-skill-$skill_name" 2>/dev/null; then
                  printf 'GC root: %s -> %s\n' "$gcroots_dir/claude-skill-$skill_name" "$store_path"
                else
                  printf 'WARNING: could not write GC root for %s; store path may be GC-eligible\n' "$skill_name" >&2
                fi
              fi
              lock_upsert "$skill_name" "$store_path"
            done
            ;;

          profile)
            for entry in "''${skills_list[@]}"; do
              skill_name=''${entry%%:*}
              store_path=''${entry#*:}
              target="$target_root/$skill_name"
              if ! nix profile install "$store_path" 2>/dev/null; then
                printf 'Note: %s already in profile; use %s to bump it\n' "$skill_name" "'nix profile upgrade'" >&2
              fi
              profile_subpath="$HOME/.nix-profile/share/claude-skills/$skill_name"
              rm -rf "$target"
              ln -sfn "$profile_subpath" "$target"
              printf 'installed (profile): %s -> %s\n' "$target" "$profile_subpath"
              lock_upsert "$skill_name" "$store_path"
            done
            printf 'manage with: nix profile list / upgrade / rollback / remove\n'
            ;;
        esac
      '';
    };

  # Shared bash helpers used by both reap and reconcile to identify which
  # `$target_root` entries are "ours" (built by this flake-skills lineage).
  # The check is layered:
  #   1. If the symlink target is live, read `.flake-skills-managed.json` and
  #      verify `managedBy == upstreamUrl`. This is the strict signal.
  #   2. If the symlink target is broken (store path GC'd), fall back to
  #      checking for a `$gcroots_dir/claude-skill-<name>` entry. This is a
  #      naming-convention signal — single-lineage assumption: a user with
  #      forks of flake-skills could see false-positives across lineages.
  ownershipBashHelpers = ''
    # is_ours_live  $entry  $upstream_url
    # Returns 0 if the symlink is alive AND its sentinel matches upstream_url.
    is_ours_live() {
      local entry="$1" upstream="$2" sentinel managed_by
      [ -L "$entry" ] || return 1
      [ -e "$entry" ] || return 1
      sentinel="$entry/.flake-skills-managed.json"
      [ -f "$sentinel" ] || return 1
      managed_by=$(jq -r '.managedBy // empty' "$sentinel" 2>/dev/null) || return 1
      [ "$managed_by" = "$upstream" ]
    }

    # is_ours_broken  $entry  $gcroots_dir
    # Returns 0 if the symlink target is missing AND a same-named GC root
    # exists (the naming-convention fallback). Best-effort.
    is_ours_broken() {
      local entry="$1" gcdir="$2" name
      [ -L "$entry" ] || return 1
      [ -e "$entry" ] && return 1
      name=$(basename "$entry")
      [ -L "$gcdir/claude-skill-$name" ] || [ -e "$gcdir/claude-skill-$name" ]
    }
  '';

  # Bash helpers for the aggregate lock file at
  # `$target_root/.flake-skills-lock.json`. The lock is a denormalized index
  # of installed skills (one entry per `$target_root/<skillName>`) drawn from
  # each skill's per-install `.flake-skills-managed.json` sentinel — same
  # data, indexed by name for human inspection (`cat $target_root/.flake-
  # skills-lock.json`). It is descriptive, not authoritative; install and
  # reconcile rebuild it from the symlinks + sentinels.
  #
  # Atomicity: tmp-write + `mv -f` so an interrupted writer can't leave a
  # half-written file behind. No advisory lock — concurrent installs of
  # the same skill name would race, but each write transitions through a
  # valid state.
  lockBashHelpers = ''
    lock_path() { printf '%s/.flake-skills-lock.json' "$target_root"; }

    lock_init_if_absent() {
      local lock; lock=$(lock_path)
      mkdir -p "$(dirname "$lock")"
      if [ ! -f "$lock" ]; then
        printf '%s\n' '{"schemaVersion":1,"skills":{}}' > "$lock"
      fi
    }

    # Read the per-install sentinel for $store_path/$skill_name. Returns
    # `{}` if the sentinel is missing (e.g. skill built by an older
    # flake-skills rev) so callers don't need to special-case it.
    lock_read_sentinel() {
      local store_path="$1" skill_name="$2"
      local sentinel="$store_path/share/claude-skills/$skill_name/.flake-skills-managed.json"
      if [ -f "$sentinel" ]; then
        cat "$sentinel"
      else
        printf '%s' '{}'
      fi
    }

    # lock_upsert  $skill_name  $store_path
    lock_upsert() {
      local skill_name="$1" store_path="$2"
      local lock tmp now sentinel
      lock=$(lock_path)
      tmp="$lock.tmp.$$"
      now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      sentinel=$(lock_read_sentinel "$store_path" "$skill_name")
      lock_init_if_absent
      jq \
        --arg name "$skill_name" \
        --argjson s "$sentinel" \
        --arg sp "$store_path" \
        --arg t "$now" \
        '.skills[$name] = ($s + {storePath: $sp, installedAt: $t})' \
        "$lock" > "$tmp"
      mv -f "$tmp" "$lock"
    }

    # lock_remove  $skill_name
    lock_remove() {
      local skill_name="$1" lock tmp
      lock=$(lock_path)
      [ -f "$lock" ] || return 0
      tmp="$lock.tmp.$$"
      jq --arg name "$skill_name" 'del(.skills[$name])' "$lock" > "$tmp"
      mv -f "$tmp" "$lock"
    }

    # lock_replace_all  "$@"  -- each arg is "name:store_path"
    # Rebuild .skills entirely from the args (used by reconcile).
    lock_replace_all() {
      local lock tmp now new_skills sentinel skill_name store_path entry
      lock=$(lock_path)
      tmp="$lock.tmp.$$"
      now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      lock_init_if_absent
      new_skills='{}'
      for entry in "$@"; do
        skill_name=''${entry%%:*}
        store_path=''${entry#*:}
        sentinel=$(lock_read_sentinel "$store_path" "$skill_name")
        new_skills=$(jq -n \
          --argjson cur "$new_skills" \
          --arg name "$skill_name" \
          --argjson s "$sentinel" \
          --arg sp "$store_path" \
          --arg t "$now" \
          '$cur + {($name): ($s + {storePath: $sp, installedAt: $t})}')
      done
      jq --argjson new "$new_skills" '.skills = $new' "$lock" > "$tmp"
      mv -f "$tmp" "$lock"
    }
  '';

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
      text = ''
        target_root=''${${envVarOverride}:-${installRoot}}
        gcroots_dir=''${NIX_GCROOTS_DIR:-/nix/var/nix/gcroots/per-user/$USER}
        upstream_url='${provenance.upstreamUrl}'

        ${ownershipBashHelpers}
        ${lockBashHelpers}

        reaped=0

        # 1. Walk $target_root/* — remove our managed entries whose symlink
        #    target is gone. Live entries are kept (reconcile handles those).
        if [ -d "$target_root" ]; then
          shopt -s nullglob
          for entry in "$target_root"/*; do
            if is_ours_broken "$entry" "$gcroots_dir"; then
              name=$(basename "$entry")
              rm -f "$entry"
              rm -f "$gcroots_dir/claude-skill-$name"
              lock_remove "$name"
              printf 'reaped (broken target): %s\n' "$entry"
              reaped=$((reaped + 1))
            fi
          done
        fi

        # 2. Walk $gcroots_dir/claude-skill-* — remove orphan GC roots whose
        #    store-path target no longer exists in the store.
        if [ -d "$gcroots_dir" ]; then
          shopt -s nullglob
          for gc in "$gcroots_dir"/claude-skill-*; do
            [ -L "$gc" ] || continue
            target=$(readlink "$gc")
            if [ ! -e "$target" ]; then
              name=''${gc##*/claude-skill-}
              rm -f "$gc"
              lock_remove "$name"
              printf 'reaped GC root (target gone): %s\n' "$gc"
              reaped=$((reaped + 1))
            fi
          done
        fi

        printf '\n%d entr(y/ies) reaped (managedBy=%s).\n' "$reaped" "$upstream_url"
      '';
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
      text = ''
        target_root=''${${envVarOverride}:-${installRoot}}
        gcroots_dir=''${NIX_GCROOTS_DIR:-/nix/var/nix/gcroots/per-user/$USER}
        upstream_url='${provenance.upstreamUrl}'

        ${ownershipBashHelpers}
        ${lockBashHelpers}

        declare -a skills_list=(
        ${skillsArrayBody skills}
        )

        mkdir -p "$target_root"
        gcroots_ok=1
        if ! mkdir -p "$gcroots_dir" 2>/dev/null; then
          gcroots_ok=0
          printf 'WARNING: could not create %s; store paths may be GC-eligible\n' "$gcroots_dir" >&2
        fi

        # 1. Install / refresh each declared skill (idempotent).
        declare -a keep_names=()
        for entry in "''${skills_list[@]}"; do
          skill_name=''${entry%%:*}
          store_path=''${entry#*:}
          skill_subpath="$store_path/share/claude-skills/$skill_name"
          target="$target_root/$skill_name"
          rm -rf "$target"
          ln -sfn "$skill_subpath" "$target"
          printf 'reconciled (install): %s -> %s\n' "$target" "$skill_subpath"
          if [ "$gcroots_ok" = "1" ]; then
            ln -sfn "$store_path" "$gcroots_dir/claude-skill-$skill_name" || \
              printf 'WARNING: could not write GC root for %s\n' "$skill_name" >&2
          fi
          keep_names+=("$skill_name")
        done

        # 2. Sweep $target_root for managed entries NOT in the declared set.
        swept=0
        if [ -d "$target_root" ]; then
          shopt -s nullglob
          for entry in "$target_root"/*; do
            name=$(basename "$entry")
            in_keep=0
            for k in "''${keep_names[@]}"; do
              if [ "$k" = "$name" ]; then
                in_keep=1
                break
              fi
            done
            [ "$in_keep" = "1" ] && continue

            if is_ours_live "$entry" "$upstream_url"; then
              rm -f "$entry"
              rm -f "$gcroots_dir/claude-skill-$name"
              printf 'reconciled (sweep): %s\n' "$entry"
              swept=$((swept + 1))
            elif is_ours_broken "$entry" "$gcroots_dir"; then
              rm -f "$entry"
              rm -f "$gcroots_dir/claude-skill-$name"
              printf 'reconciled (sweep, broken): %s\n' "$entry"
              swept=$((swept + 1))
            fi
          done
        fi

        # 3. Rewrite the aggregate lock to match the declared set exactly.
        #    Skills not in the declared set are dropped from the lock here
        #    (their symlinks/GC roots were already removed in step 2).
        if [ ''${#skills_list[@]} -gt 0 ]; then
          lock_replace_all "''${skills_list[@]}"
        else
          lock_replace_all
        fi

        printf '\n%d declared skill(s) installed; %d stray managed entr(y/ies) swept.\n' \
          "''${#keep_names[@]}" "$swept"
      '';
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
      text = ''
        target_root=''${${envVarOverride}:-${installRoot}}
        gcroots_dir=''${NIX_GCROOTS_DIR:-/nix/var/nix/gcroots/per-user/$USER}
        upstream_url='${provenance.upstreamUrl}'
        default_skill='${defaultSkillName}'

        ${ownershipBashHelpers}
        ${lockBashHelpers}

        # Help / arg parsing.
        if [ $# -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
          cat <<EOF
        Usage: uninstall-${appName} [<skill-name>...]

        Removes the install-side artifacts for each named skill:
          - \$target_root/<name>             (symlink into the Nix store)
          - \$gcroots_dir/claude-skill-<name> (per-user GC root)
          - the entry in \$target_root/.flake-skills-lock.json

        Refuses to touch entries that aren't managed by this flake-skills
        lineage (managedBy=$upstream_url).

        With no arguments: uninstalls "$default_skill" (the only skill in
        a single-skill flake). For multi-skill flakes, a name is required.

        Note: skills installed with --profile must be removed from the
        Nix profile separately (\`nix profile remove\`).

        Environment:
          ${envVarOverride}    override the install root (default: ${installRoot})
          NIX_GCROOTS_DIR    override the GC-roots dir (default: per-user dir)
        EOF
          exit 0
        fi

        # No args + default exists → uninstall the default.
        if [ $# -eq 0 ]; then
          if [ -n "$default_skill" ]; then
            set -- "$default_skill"
          else
            echo "uninstall-${appName}: skill name required" >&2
            echo "Usage: uninstall-${appName} <skill-name>..." >&2
            exit 2
          fi
        fi

        removed=0
        skipped=0
        for name in "$@"; do
          entry="$target_root/$name"
          if [ ! -L "$entry" ] && [ ! -e "$entry" ]; then
            printf 'skipped: %s is not installed\n' "$name" >&2
            skipped=$((skipped + 1))
            continue
          fi

          if is_ours_live "$entry" "$upstream_url" \
             || is_ours_broken "$entry" "$gcroots_dir"; then
            rm -f "$entry"
            rm -f "$gcroots_dir/claude-skill-$name"
            lock_remove "$name"
            printf 'uninstalled: %s\n' "$name"
            removed=$((removed + 1))
          else
            printf 'skipped: %s is not managed by %s\n' "$name" "$upstream_url" >&2
            skipped=$((skipped + 1))
          fi
        done

        printf '\n%d uninstalled, %d skipped.\n' "$removed" "$skipped"
        # Exit non-zero if every requested name was skipped — the user
        # probably typo'd or invoked uninstall on something they didn't
        # install via this flake.
        if [ "$removed" = "0" ] && [ "$skipped" -gt 0 ]; then
          exit 1
        fi
      '';
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
      text = ''
        target_root=''${${envVarOverride}:-${installRoot}}

        printf '%s preview (no changes made)\n\n' '${displayName}'
        printf 'Target directory: %s\n' "$target_root"
        printf '  (override with %s)\n\n' '${envVarOverride}'

        declare -a skills_list=(
        ${skillsArrayBody skills}
        )

        count=0
        for entry in "''${skills_list[@]}"; do
          skill_name=''${entry%%:*}
          store_path=''${entry#*:}
          skill_subpath="$store_path/share/claude-skills/$skill_name"
          size=$(du -shL "$skill_subpath" 2>/dev/null | cut -f1)
          printf '  %s  (%s)\n' "$skill_name" "$size"
          find -L "$skill_subpath" -mindepth 1 ! -type d | sed "s|^$skill_subpath/|      |"
          count=$((count + 1))
        done

        printf '\n%d skill(s) total.\n' "$count"
        printf '\nTo install (default — symlink + GC root):\n'
        printf "  nix run '.#install'\n"
        printf '\nTo install via nix profile (shows up in nix profile list):\n'
        printf "  nix run '.#install' -- --profile\n"
        printf '\n(preview only — no files were written)\n'
      '';
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
