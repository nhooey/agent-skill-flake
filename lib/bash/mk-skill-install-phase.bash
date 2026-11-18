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
install -Dm644 "$sentinelPath" \
  "$skill_dir/.agent-skill-flake-managed.json"
runHook postInstall
