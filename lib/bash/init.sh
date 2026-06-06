# Consumer-repo scaffolder for the dev-shell skills pattern. Run from a
# consumer repo's root: `nix run <upstream>#init`.
#
# WHY a scaffolder rather than more library: a flake's `inputs` must be
# static literals the evaluator reads BEFORE `outputs` runs, so the
# per-consumer `skills-devshell/flake.nix` (its inputs + the
# mkDevshellSkillsFlake call) and the `.gitignore` entry cannot be factored
# into a lib the way the rest of the wiring is. The only lever for writing
# those literals into each consumer is this scaffolder.
#
# Injected by the Nix wrapper (see lib/internal.nix mkInit):
#   upstream_url            canonical agent-skill-flake URL (lib upstreamUrl)
#   devshell_flake_template store path of skills-devshell/flake.nix template
# The template carries @UPSTREAM_URL@ / @NAME@ placeholders we substitute.

app_name="${app_name:-init}"

print_help() {
  cat <<EOF
Usage: $app_name [--force] [--dry-run] [-h|--help]

Scaffolds the dev-shell skills pattern into the CURRENT repo (run from its
root). Writes, idempotently and without clobbering:

  skills-devshell/flake.nix   a sub-flake calling mkDevshellSkillsFlake
  .gitignore                  appends a /.claude/skills/ line if missing

and prints the root flake.nix wiring snippet for you to paste (never edits
your root flake.nix — too varied to touch safely).

Options:
  --force     Overwrite skills-devshell/flake.nix if present.
  --dry-run   Print what would be written; change nothing on disk.
  -h, --help  Show this help and exit.
EOF
}

force=0
dry_run=0
for arg in "$@"; do
  case "$arg" in
  -h | --help)
    print_help
    exit 0
    ;;
  --force) force=1 ;;
  --dry-run) dry_run=1 ;;
  *)
    printf 'error: unknown argument: %s\n\n' "$arg" >&2
    print_help >&2
    exit 2
    ;;
  esac
done

# Resolve the consumer repo name: prefer the origin remote's basename (so a
# clone in a renamed directory still gets its canonical name), fall back to
# the CWD basename when there is no remote (fresh `git init`, or no git).
repo=""
if remote_url=$(git remote get-url origin 2>/dev/null) && [ -n "$remote_url" ]; then
  repo=$(basename "${remote_url%.git}")
fi
if [ -z "$repo" ]; then
  repo=$(basename "$PWD")
fi

# Fail loud on a name we cannot safely interpolate. This mirrors
# resolveNamespace in lib/internal.nix, which errors rather than inventing a
# name. A safe name also keeps it out of trouble as a Nix `name`/path segment.
if ! printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
  printf 'init: could not derive a safe repo name from %s\n' "'$repo'" >&2
  printf '      rename the directory or set the git remote so the name matches [A-Za-z0-9._-]\n' >&2
  exit 1
fi

# Each action prints exactly one status line so a run is auditable; the
# dry-run path takes the same branches but stops short of writing.
note() { printf '%s\n' "$*"; }

# write_file <path> <content> <allow-overwrite>
# Honors --dry-run (announce only) and refuses to clobber an existing file
# unless allowed (the per-file --force gate).
write_file() {
  local path=$1 content=$2 allow_overwrite=$3

  if [ -e "$path" ] && [ "$allow_overwrite" -eq 0 ]; then
    note "skip   $path (exists; use --force to overwrite)"
    return 0
  fi

  local verb="create"
  [ -e "$path" ] && verb="overwrite"

  if [ "$dry_run" -eq 1 ]; then
    note "would $verb $path"
    return 0
  fi

  mkdir -p "$(dirname "$path")"
  # `$content` arrives via command substitution, which strips trailing
  # newlines, so re-add exactly one — every file we write must end in a
  # newline (the scaffolded flake.nix is otherwise nixfmt-dirty).
  printf '%s\n' "$content" >"$path"
  note "$verb $path"
}

# 1. The skills-devshell sub-flake. Substitute the canonical upstream URL
# and the resolved repo name into the template, then write it.
# Escape the sed replacement text: `&` (the matched text), the `|` delimiter,
# and `\` would otherwise corrupt or hard-fail the substitution. `repo` is
# already validated above; `upstream_url` is a github: ref, but we escape both
# defensively so no value can corrupt the output.
esc() { printf '%s' "$1" | sed -e 's/[&\\|]/\\&/g'; }
devshell_flake=$(
  sed \
    -e "s|@UPSTREAM_URL@|$(esc "$upstream_url")|g" \
    -e "s|@NAME@|$(esc "$repo")|g" \
    "$devshell_flake_template"
)
write_file "skills-devshell/flake.nix" "$devshell_flake" "$force"

# 2. The .gitignore entry. Idempotent append: only add the line if no
# existing line matches it exactly (create the file if absent). --dry-run
# announces but does not write.
gitignore_line="/.claude/skills/"
if [ -f .gitignore ] && grep -qxF "$gitignore_line" .gitignore; then
  note "skip   .gitignore ($gitignore_line already present)"
elif [ "$dry_run" -eq 1 ]; then
  note "would append $gitignore_line to .gitignore"
else
  # Keep the file newline-terminated even if it lacked a trailing newline.
  if [ -s .gitignore ] && [ -n "$(tail -c 1 .gitignore)" ]; then
    printf '\n' >>.gitignore
  fi
  printf '%s\n' "$gitignore_line" >>.gitignore
  note "append $gitignore_line to .gitignore"
fi

# 3. Root flake.nix wiring. We never edit the root flake (too varied to touch
# safely) — we print the snippet for the user to paste themselves.
cat <<EOF

────────────────────────────────────────────────────────────────────────
Paste this into your ROOT flake.nix (flake-parts):

  inputs.agent-skill-flake.url = "$upstream_url";

  # inside outputs / mkFlake:
  imports = [ inputs.agent-skill-flake.flakeModules.devshellSkills ];
  agent-skill-flake.devshellSkills = { name = "$repo"; };

Not using flake-parts? Wire the root devShell by hand instead: import
\`agent-skill-flake.lib.devshellSkillsHook\` and splice its \`startup\`,
\`standardCommands\`, and \`commands\` into your devshell.

Next: edit skills-devshell/flake.nix to fill in \`sources\`, then run
  nix flake lock ./skills-devshell
────────────────────────────────────────────────────────────────────────
EOF
