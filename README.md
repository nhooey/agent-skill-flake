# flake-skills

[![built with garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fnhooey%2Fflake-skills)](https://garnix.io/repo/nhooey/flake-skills)

A tiny Nix flake providing two functions for building installable Nix flakes
from [Claude Code agent-skill][skills] directories:

- **`lib.mkSkillFlake`** — turn a single skill directory into a flake.
- **`lib.mkAllSkillsFlake`** — turn a directory of skills into one
  multi-skill flake (auto-discovery + aggregate install/preview).

Use these to skip the boilerplate of wiring up `packages` / `apps` /
install / preview by hand. The canonical multi-skill consumer is
[`nhooey/skills-nix`][skills-nix].

[skills]: https://www.anthropic.com/engineering/agent-skills
[skills-nix]: https://github.com/nhooey/skills-nix

## Single-skill: `mkSkillFlake`

A per-skill `flake.nix` is ten lines:

```nix
# skills/my-skill/flake.nix
{
  description = "my-skill: Claude Code skill for X";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-skills.url = "github:nhooey/flake-skills";
  };
  outputs = { nixpkgs, flake-skills, ... }:
    flake-skills.lib.mkSkillFlake {
      inherit nixpkgs;
      skillName = "my-skill";
      src = ./.;
    };
}
```

That gives you, for the four standard systems
(`x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin`):

```sh
nix run .#preview   -- --scope=personal              # preview at $HOME/.claude/skills/
nix run .#install   -- --scope=personal              # install at $HOME/.claude/skills/
nix run .#install   -- --scope=project               # install at <repo-root>/.claude/skills/
nix run .#install   -- --scope=custom --root=/tmp/x  # install at the named path
nix run .#install   -- --scope=personal --profile    # via `nix profile install`
nix run .#uninstall -- --scope=personal              # remove the skill
nix run .#reap      -- --scope=personal              # remove broken managed entries
nix build .#my-skill                                 # produce $out/share/claude-skills/my-skill/
```

`--scope` is **required** on every install/uninstall/reap/reconcile/preview
invocation — there is no implicit default. See
[Install scope](#install-scope) for the resolver semantics.

### `mkSkillFlake` API

```nix
flake-skills.lib.mkSkillFlake {
  nixpkgs        = <flake input>;
  skillName      = "my-skill";
  src            = ./.;
  # optional:
  systems        = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
  description    = "Claude Code skill: my-skill";
  version        = "0.1.0";
  extraDirs      = [ ];           # ship additional top-level dirs alongside SKILL.md/references/scripts
  extraFiles     = [ ];           # ship additional top-level files (shell globs evaluated in `src`)
  agent          = "claude-code"; # selects an agent profile (see "Targeting other agents")
  # rename (optional) — see "Renaming & name collisions" below:
  renameFn       = ctx: ctx.name; # identity (no rename)
  source         = null;          # skill's origin repo, for ctx.source.*
  packageName    = null;          # defaults to "skill-${effectiveName}"
}
```

| Param         | Required | Default                                                              | Meaning |
|---------------|----------|----------------------------------------------------------------------|---------|
| `nixpkgs`     | yes      | —                                                                    | The consumer's `nixpkgs` flake input. Passed in so the consumer controls pinning. |
| `skillName`   | yes      | —                                                                    | String. The skill's name (e.g. `"garnix-ci"`), before any `renameFn`. The installed `SKILL.md` frontmatter `name:` is **normalized** to the effective name at build time. |
| `src`         | yes      | —                                                                    | Path to the skill directory (typically `./.` from the per-skill `flake.nix`). |
| `systems`     | no       | `[ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ]` | Systems to build for. |
| `description` | no       | `"Claude Code skill: ${skillName}"`                                  | `meta.description` on the skill derivation. |
| `version`     | no       | `"0.1.0"`                                                            | Skill package version. |
| `extraDirs`   | no       | `[ ]`                                                                | Additional top-level directories from `src` to ship into the install. Use for upstream skills with non-standard layouts. Missing dirs are silently ignored. |
| `extraFiles`  | no       | `[ ]`                                                                | Additional top-level files from `src` to ship at the install root. Each entry is a shell glob evaluated in `src` (nullglob: no-match silently dropped; directory matches are skipped). |
| `agent`       | no       | `"claude-code"`                                                      | Which agent's filesystem layout to target. See [Targeting other agents](#targeting-other-agents). Throws at eval if the name isn't a known profile. |
| `renameFn`    | no       | `ctx: ctx.name`                                                      | Formula deriving the effective name from a context attrset. See [Renaming & name collisions](#renaming--avoiding-claude-code-name-collisions). |
| `source`      | no       | `null`                                                               | The skill's origin repo, supplied from your flake `self` (+ owner/repo). Only needed if `renameFn` reads `ctx.source.*`. |
| `packageName` | no       | `null` → `"skill-${effectiveName}"`                                  | Override the `packages.<system>.<key>` attribute name. |

Returns an attrset suitable for use as a flake's `outputs`:

```nix
{
  packages = forAllSystems (system: {
    default       = <skill derivation>;
    ${skillName}  = <skill derivation>;
  });
  apps = forAllSystems (system: {
    default   = { type = "app"; program = "<preview>"; };
    install   = { type = "app"; program = "<install>"; };
    uninstall = { type = "app"; program = "<uninstall>"; };
    preview   = { type = "app"; program = "<preview>"; };
    reap      = { type = "app"; program = "<reap>"; };
  });
}
```

## Multi-skill: `mkAllSkillsFlake`

If you have a directory of skills (one subdirectory per skill, each with a
`SKILL.md`), `mkAllSkillsFlake` builds a single flake that exposes them all.
The top-level repo flake stays ~10 lines:

```nix
# repo-root/flake.nix
{
  description = "skills-nix: Claude Code skills marketplace";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-skills.url = "github:nhooey/flake-skills";
    flake-skills.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { nixpkgs, flake-skills, ... }:
    flake-skills.lib.mkAllSkillsFlake {
      inherit nixpkgs;
      skillsDir = ./skills;
    };
}
```

It auto-discovers every subdirectory of `skillsDir` that contains a
`SKILL.md`, builds each as its own skill derivation, and exposes:

```sh
nix run .#install -- --scope=personal                   # all skills, personal scope
nix run .#install -- --scope=project nix-flakes git-ssh # subset by name, project scope
nix run .#install -- --scope=personal --profile         # via nix profile
nix run .#uninstall -- --scope=personal <name>...       # remove one or more
nix run .#reap      -- --scope=personal                 # remove broken managed entries
nix run .#reconcile -- --scope=personal                 # install declared set, sweep strays
nix build .#all                                         # symlinkJoin'd derivation for all skills
nix build .#<skill-name>                                # single skill derivation
```

The aggregate installer creates one symlink and one GC root per skill, using
exactly the same machinery as the single-skill installer.

### `mkAllSkillsFlake` API

```nix
flake-skills.lib.mkAllSkillsFlake {
  nixpkgs        = <flake input>;
  skillsDir      = ./skills;
  # optional:
  systems        = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
  name           = "agent-skills-all";
  agent          = "claude-code"; # selects an agent profile (see "Targeting other agents")
  extraDirs      = [ ];           # additional top-level dirs (applied to every discovered skill)
  extraFiles     = [ ];           # additional top-level files (shell globs; applied to every discovered skill)
  # rename (optional) — see "Renaming & name collisions" below:
  renameFn       = ctx: ctx.name; # identity (no rename)
  source         = null;          # skills' origin repo, for ctx.source.*
}
```

| Param        | Required | Default                                                              | Meaning |
|--------------|----------|----------------------------------------------------------------------|---------|
| `nixpkgs`    | yes      | —                                                                    | The consumer's `nixpkgs` flake input. |
| `skillsDir`  | yes      | —                                                                    | Path to a directory whose subdirectories are individual skills. A subdir is a "skill" iff it contains a `SKILL.md`. |
| `systems`    | no       | `[ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ]` | Systems to build for. |
| `name`       | no       | `"agent-skills-all"`                                                 | Aggregate derivation name (also used as the install/preview app suffix). |
| `agent`      | no       | `"claude-code"`                                                      | Which agent's filesystem layout to target. See [Targeting other agents](#targeting-other-agents). |
| `extraDirs`  | no       | `[ ]`                                                                | Additional top-level directories to ship into each discovered skill's install. Applied uniformly to every skill; missing dirs are silently ignored. |
| `extraFiles` | no       | `[ ]`                                                                | Additional top-level files to ship at each discovered skill's install root. Each entry is a shell glob evaluated per-skill (nullglob: no-match silently dropped; directory matches are skipped). |
| `renameFn`   | no       | `ctx: ctx.name`                                                      | Per-skill name formula. See [Renaming & name collisions](#renaming--avoiding-claude-code-name-collisions). |
| `source`     | no       | `null`                                                               | The skills' origin repo, supplied from your flake `self` (+ owner/repo). Only needed if `renameFn` reads `ctx.source.*`. |

Returns:

```nix
{
  packages = forAllSystems (system: {
    default       = <symlinkJoin of every discovered skill>;
    all           = <same>;
    ${skillName1} = <skill 1 derivation>;
    ${skillName2} = <skill 2 derivation>;
    # ...one entry per discovered skill
  });
  apps = forAllSystems (system: {
    default   = { type = "app"; program = "<aggregate preview>"; };
    install   = { type = "app"; program = "<aggregate installer>"; };
    uninstall = { type = "app"; program = "<uninstaller>"; };
    preview   = { type = "app"; program = "<aggregate preview>"; };
    reap      = { type = "app"; program = "<reap>"; };
    reconcile = { type = "app"; program = "<reconcile>"; };
  });
}
```

Discovery rules:

- Subdirectory of `skillsDir` is a skill iff it contains a `SKILL.md`.
- Subdir name becomes the skill name (after `renameFn`). You do **not**
  have to keep the `SKILL.md` frontmatter `name:` in sync by hand — the
  build normalizes it to the effective name (see
  [Renaming & name collisions](#renaming--avoiding-claude-code-name-collisions)).
- Files at the top of `skillsDir` (e.g. a `README.md`), or subdirs without a
  `SKILL.md`, are silently ignored.
- Per-skill source filtering is identical to the single-skill case: only
  `SKILL.md`, `references/`, and `scripts/` are copied into the output;
  everything else (`flake.nix`, dotfiles, etc.) is ignored.

## Build behavior

The skill derivation produces:

```
$out/share/claude-skills/<skillName>/
├── SKILL.md          # required, mode 644
├── references/       # copied recursively if present
├── scripts/          # copied recursively if present
├── <extraDirs[*]>/   # any directories listed in `extraDirs`, copied recursively if present
└── <extraFiles[*]>   # any top-level files matching the `extraFiles` shell globs, mode 644
```

Everything else in `src` is ignored — including `flake.nix`, `flake.lock`,
hidden dotfiles, and any other top-level files. If a skill ships content in
non-standard top-level directories (e.g. `agents/`, `assets/`), name them in
`extraDirs`. If `SKILL.md` cross-references loose flat companion files at
the source root (e.g. `obra/superpowers`' `visual-companion.md`,
`code-reviewer.md`), match them with `extraFiles` shell globs (e.g.
`[ "*.md" "*.sh" "*.dot" ]`). Anything not matched by the whitelist is
still ignored.

The expected source layout matches the [Anthropic agent-skill format][skills]:

```
my-skill/
├── SKILL.md          # required — frontmatter + instructions
├── references/       # optional — long-form docs
└── scripts/          # optional — executable helpers
```

The `SKILL.md` frontmatter `name:` is **normalized at build time** to the
effective skill name (post-`renameFn`), so the source value doesn't have to
match `skillName` / the directory — see the next section.

## Renaming & avoiding Claude Code name collisions

Claude Code has a **flat skill namespace**: a skill's identity is its
`SKILL.md` frontmatter `name:` (falling back to the directory name), and
same-named skills across scopes resolve by silent precedence
(enterprise > personal > project > plugin), with built-ins shadowing
custom skills. Generic names (`git`, `review`, `loop`, …) collide.

`renameFn` is the supported escape hatch. It is a **formula** — a function
from a context attrset to the effective name — not a fixed string, so a
derived name can encode where the skill came from:

```nix
flake-skills.lib.mkAllSkillsFlake {
  inherit nixpkgs;
  skillsDir = ./skills;
  source = {                       # from YOUR flake's `self` + owner/repo
    owner = "nhooey";
    repo  = "skills-nix";
    rev              = self.rev or self.dirtyRev;
    lastModifiedDate = self.lastModifiedDate;   # "%Y%m%d%H%M%S"
    narHash          = self.narHash;
  };
  # e.g. git → "nhooey-git-1a2b3c4-20260519"
  renameFn = ctx:
    "${ctx.source.owner}-${ctx.name}-${ctx.source.shortRev}-${ctx.source.lastModifiedCompact}";
}
```

The context passed to `renameFn`:

```nix
{
  name = "<original skill name>";   # discovered dir name / skillName

  source = {                        # the skill's origin repo (from `source`)
    owner; repo; url;               # url: any git URL/flake ref, host-agnostic
    rev;                            # full, with any "-dirty" stripped
    shortRev;                       # rev[:7] (or source.shortRev)
    dirty;                          # bool
    narHash;
    lastModified;                   # raw epoch, passed through (or null)
    lastModifiedDate;               # "YYYY-MM-DD"  (UTC)
    lastModifiedCompact;            # "YYYYMMDD"    (UTC)
  };

  tooling = {                       # the flake-skills lineage that built it
    owner; repo; url; rev; shortRev; dirty; narHash;
  };
}
```

`lastModifiedDate` / `lastModifiedCompact` are sliced from the source's
`lastModifiedDate` — the `"%Y%m%d%H%M%S"` UTC string Nix already puts on
`self` (nixpkgs derives dates from it the same way; no epoch math). They
are null unless you pass `source.lastModifiedDate`. This is the source
tree's git last-modified time as Nix sees it (commit date for a clean
checkout) — flake-level, not per-skill, since pure eval can't get
per-file git mtime without IFD. `owner`/`repo` come from explicit
`source.owner`/`repo`, or are parsed best-effort from `source.url` for
any host (for >2 path segments — GitLab subgroups, Gitea — the last two
segments are taken). When `source` is `null`, all `ctx.source.*` fields
are `null`; only pass `source` if your formula reads them.

Rules and guarantees:

- The result **must** match Claude Code's name constraint
  `^[a-z0-9-]{1,64}$` (lowercase letters, digits, hyphens; ≤64 chars).
  An invalid derived name fails `nix flake check` with a clear message —
  it never silently produces an unloadable skill.
- The renamed name is the skill's **real identity everywhere**: the
  install directory, the slash command, the `SKILL.md` frontmatter
  `name:` (rewritten in place), the sentinel `skillName`, the GC root,
  the lock entry, and (unless `packageName` is set) the package key.
- The pre-rename name is preserved in each skill's
  `.flake-skills-managed.json` sentinel as `originalSkillName`, so a
  remapped install is still traceable to what it was called upstream.
- For `mkSkillFlake`, `ctx.name` is `skillName`; "specifying a new name"
  is just setting `skillName` (or a constant `renameFn`). For
  `mkAllSkillsFlake`, `renameFn` is the per-skill formula applied across
  the whole discovered set.

## Install scope

Every install/uninstall/reap/reconcile/preview invocation **must** declare
its `--scope`. There is no implicit default — the choice is forced at the
call site so an install can never silently land in a place the caller
didn't choose. The three scopes:

```sh
# Personal: $HOME/<agent.personalSuffix>/  (e.g. $HOME/.claude/skills/)
nix run .#install -- --scope=personal

# Project:  <project-root>/<agent.projectSuffix>/
#           Walks up from $PWD looking for .git/ (preferred), then
#           flake.nix. Hard-errors if neither marker is found.
nix run .#install -- --scope=project

# Custom:   the literal path you name.
nix run .#install -- --scope=custom --root=/etc/agent-skills
```

`--scope=custom` requires `--root=<path>`; `--root` is rejected with any
other scope. Missing `--scope` exits non-zero with a usage hint. Other
flags:

| Flag                  | Default                              | Meaning |
|-----------------------|--------------------------------------|---------|
| `--gcroots-dir=<path>`| `/nix/var/nix/gcroots/per-user/$USER`| Override the per-user GC-roots dir. Primarily for the test suite — rarely useful in practice. |
| `--profile`           | (off)                                | `install` only: install via `nix profile install` instead of the default direct-symlink mode. See [`--profile`](#--profile-via-nix-profile-install). |
| `-h`, `--help`        | —                                    | Print help and exit. |

Positional args after the flags are skill-name selectors (subset install):

```sh
nix run .#install -- --scope=project nix-flakes git-ssh
```

`mkAllSkillsFlake` apps install all discovered skills with no positional
args, or only the named subset when given. An unknown skill name is a
hard error listing what's available — the install-time equivalent of
eval-time typo protection.

### Default: symlink + GC root

The Nix-native install. Three things happen:

1. **User-facing symlink.**
   `<target>/<skillName>` is created as a symlink to
   `<store-path>/share/claude-skills/<skillName>`. Claude Code (or
   whichever agent profile you picked) follows it transparently.
2. **Per-user GC root.**
   `/nix/var/nix/gcroots/per-user/$USER/claude-skill-<skillName>` is
   created as a symlink to the store derivation. This protects the
   store path from `nix-store --gc`. Override the gcroots dir with
   `--gcroots-dir=<path>` (test-suite use; rarely useful in practice).
3. **Aggregate lock entry.**
   An entry is upserted into `<target>/.flake-skills-lock.json`
   summarizing what was installed (provenance from the per-skill
   sentinel + the resolved `storePath` + an `installedAt` timestamp).
   See [Lock file](#lock-file) below.

The user-facing symlink is read-only by virtue of pointing into the
store. To **upgrade** a skill, re-run `nix run .#install`: the symlink
is replaced atomically, the new store path becomes the GC root, the
old path becomes GC-eligible, and the lock entry is refreshed.

### `--profile`: via `nix profile install`

If you want skills to participate in the `nix profile` machinery
(`list`/`upgrade`/`rollback`/`remove`):

```sh
nix run .#install -- --scope=personal --profile
```

This calls `nix profile install <store-path>`, then symlinks
`<target>/<skillName>` into `~/.nix-profile/share/claude-skills/`. GC
protection comes from the profile itself; no separate GC root. The
aggregate lock is updated the same way as in symlink mode.

To **upgrade** in this mode: `nix profile upgrade --regex 'claude-skill-<name>'`.

## Uninstall behavior

```sh
nix run .#uninstall -- --scope=personal              # single-skill flake: removes that skill
nix run .#uninstall -- --scope=personal <name>       # multi-skill flake: removes one by name
nix run .#uninstall -- --scope=personal alpha beta   # multiple at once
```

Removes all three install-side artifacts:

- the user-facing symlink at `<target>/<name>`,
- the per-user GC root at `<gcroots-dir>/claude-skill-<name>`,
- the entry in `<target>/.flake-skills-lock.json`.

It refuses to touch entries it can't confidently identify as managed by
this flake-skills lineage (the sentinel must say `managedBy=<this
lineage>`, or — if the symlink target has been GC'd — a same-named GC
root must exist as a naming-convention fallback). A user's hand-rolled
`~/.claude/skills/foo` directory is therefore safe even if `foo`
happens to match a flake-skills skill name.

For `--profile`-mode installs, `nix run .#uninstall` removes the
user-facing symlink + lock entry, but the entry stays in the Nix
profile. Run `nix profile remove` separately to drop it from the
profile.

## Lock file

`<target>/.flake-skills-lock.json` is a single-file index of every skill
this flake-skills lineage has installed under that target. Same data as
the per-skill sentinels (`<target>/<name>/.flake-skills-managed.json`),
indexed by name so you can `cat` it for an overview:

```json
{
  "schemaVersion": 1,
  "skills": {
    "garnix-ci": {
      "schemaVersion": 2,
      "managedBy": "github:nhooey/flake-skills",
      "managedByRev": "abc123...",
      "managedByDirty": false,
      "managedByNarHash": "sha256-...",
      "skillName": "garnix-ci",
      "originalSkillName": "garnix-ci",
      "version": "0.1.0",
      "storePath": "/nix/store/...-claude-skill-garnix-ci-0.1.0",
      "installedAt": "2026-04-27T12:34:56Z"
    }
  }
}
```

The lock is **descriptive, not authoritative**: install / reconcile / reap /
uninstall rebuild it from the symlinks + sentinels, so editing it by hand has
no lasting effect. The source of truth is still the symlink + GC root + the
sentinel inside each store path.

Atomicity: each writer goes through tmp-file + `mv -f`, so a crashed installer
can't leave a half-written file behind. Concurrent installers of distinct
skills are safe; concurrent installers of the **same** skill name race on the
last-writer-wins, same as they would on the symlink itself.

## Targeting other agents

The defaults target Claude Code's `~/.claude/skills/` directory via the
`claude-code` agent profile. To support
[Codex][codex], [Cursor][cursor], or any other agent that adopts the
same skill format, pick a different `agent`:

```nix
flake-skills.lib.mkSkillFlake {
  inherit nixpkgs;
  skillName = "my-skill";
  src       = ./.;
  agent     = "codex";   # → installs at $HOME/.codex/skills/ for --scope=personal
}
```

Built-in profiles (see [`lib/agent-profiles.nix`](lib/agent-profiles.nix)):

| `agent`        | personal-scope (`$HOME/…`) | project-scope (`<root>/…`) |
|----------------|----------------------------|----------------------------|
| `claude-code`  | `.claude/skills`           | `.claude/skills`           |
| `codex`        | `.codex/skills`            | `.codex/skills`            |
| `cursor`       | `.cursor/skills`           | `.cursor/skills`           |

To add a new agent, append an entry to `lib/agent-profiles.nix`. An
unknown `agent` value throws at eval with the list of known profiles.

[codex]: https://github.com/openai/codex
[cursor]: https://www.cursor.com/

## Migration from pre-scope versions

Pre-scope releases used `installRoot` and `envVarOverride` parameters
on `mkSkillFlake` / `mkAllSkillsFlake`, plus an implicit
`$HOME/.claude/skills/` default and a `CLAUDE_SKILLS_DIR` env-var
override. All of those are gone:

- Replace `installRoot = "$HOME/.codex/skills"` /
  `envVarOverride = "CODEX_SKILLS_DIR"` with `agent = "codex"`.
- Replace `installRoot = "/some/custom/path"` at install time with
  `nix run .#install -- --scope=custom --root=/some/custom/path`.
- Replace `CLAUDE_SKILLS_DIR=…` env overrides with the same
  `--scope=custom --root=…` flags.
- Replace `services.flake-skills.installRoot` /
  `programs.flake-skills.installRoot` module options with
  `scope = "personal" | "project" | "custom";` (and `root = "..."` when
  `scope = "custom"`).

The home-manager / nix-darwin module options now require `scope` to be
set explicitly — there is no default. `scope = "personal"` is the usual
choice for a home-manager activation.

## Stability

The public surface is `lib.mkSkillFlake` and `lib.mkAllSkillsFlake`.
Consumers should pin via `flake.lock`. The pre-`--scope` API
(`installRoot` / `envVarOverride` / `CLAUDE_SKILLS_DIR`) is gone in
this release — see [Migration from pre-scope versions](#migration-from-pre-scope-versions)
for the swap.

## Canonical consumer

[`nhooey/skills-nix`][skills-nix] uses `mkAllSkillsFlake` for its top-level
flake and `mkSkillFlake` for each per-skill flake. It is the reference
example of the multi-skill aggregation pattern.

## License

[Apache-2.0](LICENSE)
