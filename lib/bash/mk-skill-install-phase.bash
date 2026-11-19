# shellcheck shell=bash
# shellcheck disable=SC2154 # set by the derivation: out, sentinelPath, extra*Args
#
# mkSkill's installPhase (lib/internal.nix), sourced from it after
# `pkgs.replaceVars` fills each placeholder below with a value escaped
# by `lib.escapeShellArg`:
#
#   name                    the skill's installed name
#   normalizeFrontmatterAwk lib/normalize-frontmatter.nix, as a file
#   scriptInputsPath        the scriptInputs' bin PATH, empty for none
#   scriptInputsNames       the scriptInputs' names, empty for none
#   contentHashBash         ./content-hash.bash, as a file
#
# extraFiles and extraDirs arrive as the derivation attributes
# `extraFilesArgs` and `extraDirsArgs`, each a space-separated list of
# `lib.escapeShellArg` words, which eval turns back into arrays.
runHook preInstall
skill_name=@name@
eval "extra_files=($extraFilesArgs)"
eval "extra_dirs=($extraDirsArgs)"
normalize_frontmatter_awk=@normalizeFrontmatterAwk@
script_inputs_path=@scriptInputsPath@
script_inputs_names=@scriptInputsNames@
skill_dir="$out/share/claude-skills/$skill_name"
mkdir -p "$skill_dir"
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
for pat in "${extra_files[@]}"; do
  # shellcheck disable=SC2231 # $pat is a glob, expanded on purpose
  for f in $pat; do
    [ -f "$f" ] || continue
    install -Dm644 "$f" "$skill_dir/$(basename "$f")"
  done
done
shopt -u nullglob
awk -v newname="$skill_name" \
  -f "$normalize_frontmatter_awk" \
  SKILL.md >"$skill_dir/SKILL.md"
chmod 644 "$skill_dir/SKILL.md"
for d in references scripts "${extra_dirs[@]}"; do
  if [ -d "$d" ]; then
    mkdir -p "$skill_dir/$d"
    cp -r "$d/." "$skill_dir/$d/"
  fi
done
# The sentinel's `contentHash`, taken here: before scriptInputs and
# fixup's shebang patching write store paths into the scripts, so
# the same source hashes the same against any nixpkgs. The script
# inputs' names count; their store paths don't.
SENTINEL_FILE=.agent-skill-flake-managed.json
# shellcheck source=/dev/null # a store path
source @contentHashBash@
content_hash=$(skill_content_hash "$skill_dir")
if [ -n "$script_inputs_path" ]; then
  content_hash=$(content_hash_extend "$content_hash" "scriptInputs $script_inputs_names")
fi
if [ -n "$script_inputs_path" ]; then
  # A shell script gets the PATH line after its shebang, so it
  # keeps its path and runs under any bash, macOS's 3.2 among
  # them, which misreads makeWrapper's PATH edits when a skill
  # runs it as `bash <script>`. Any other executable is wrapped.
  for f in "$skill_dir/scripts/"*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    if head -n 1 "$f" | grep -Eq '^#!.*[/ ](ba|da|k|z)?sh( |$)'; then
      # shellcheck disable=SC2016 # the PATH reference is for the script
      sed -i "1a PATH=$script_inputs_path"'${PATH:+:$PATH}; export PATH' "$f"
    else
      wrapProgram "$f" --prefix PATH : "$script_inputs_path"
    fi
  done
fi
jq -cS --arg h "$content_hash" '.contentHash = $h' "$sentinelPath" \
  >"$skill_dir/$SENTINEL_FILE"
chmod 644 "$skill_dir/$SENTINEL_FILE"
runHook postInstall
