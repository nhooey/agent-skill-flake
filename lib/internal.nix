{ nixpkgs }:
let
  inherit (nixpkgs) lib;

  mkSkill =
    system:
    {
      name,
      src,
      version ? "0.1.0",
      description ? "Claude Code skill: ${name}",
      # Provenance from lib/default.nix: which flake-skills lineage built
      # this, what rev / dirty state, and the source narHash for
      # differentiation across dirty builds. Written verbatim into the
      # `.flake-skills-managed.json` sentinel so reconcile/reap can decide
      # what's "ours" without needing flake metadata at runtime.
      provenance,
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      sentinel = builtins.toJSON {
        schemaVersion = 1;
        managedBy = provenance.upstreamUrl;
        managedByRev = provenance.rev;
        managedByDirty = provenance.dirty;
        managedByNarHash = provenance.narHash;
        skillName = name;
        inherit version;
      };
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "claude-skill-${name}";
      inherit version src;
      dontBuild = true;
      # Pass the JSON via env so we don't have to escape it inside the bash
      # heredoc; bash will see it as a single literal string.
      passAsFile = [ "sentinel" ];
      inherit sentinel;
      installPhase = ''
        runHook preInstall
        install -Dm644 SKILL.md "$out/share/claude-skills/${name}/SKILL.md"
        for d in references scripts; do
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
    if skills == [ ] then
      ""
    else
      lib.concatMapStringsSep "\n" (s: ''  "${s.name}:${s.drv}"'') skills;

  mkInstaller =
    system:
    {
      appName,
      skills,
      installRoot,
      envVarOverride,
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    pkgs.writeShellApplication {
      name = "install-${appName}";
      runtimeInputs = with pkgs; [
        coreutils
        nix
      ];
      text = ''
        target_root=''${${envVarOverride}:-${installRoot}}

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

  mkReap =
    system:
    {
      appName,
      provenance,
      installRoot,
      envVarOverride,
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
              rm -f "$gc"
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
    {
      appName,
      skills,
      provenance,
      installRoot,
      envVarOverride,
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

        printf '\n%d declared skill(s) installed; %d stray managed entr(y/ies) swept.\n' \
          "''${#keep_names[@]}" "$swept"
      '';
    };

  mkPreview =
    system:
    {
      appName,
      displayName,
      skills,
      installRoot,
      envVarOverride,
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
    discoverSkills
    mkInstaller
    mkPreview
    mkReap
    mkReconcile
    ;
}
