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
nix run .                       # read-only preview (no side effects)
nix run .#preview               # same as default
nix run .#install               # symlink into ~/.claude/skills/ + GC root
nix run .#install -- --profile  # install via 'nix profile' instead
nix run .#uninstall             # remove the skill (symlink + GC root + lock entry)
nix run .#reap                  # remove broken/dead managed entries
nix build .#my-skill            # produce $out/share/claude-skills/my-skill/
```

The default `nix run` is the **preview** — it lists the files that would be
installed and the target path, but writes nothing. The explicit `#install`
app is the only one with side effects.

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
  installRoot    = "$HOME/.claude/skills";
  envVarOverride = "CLAUDE_SKILLS_DIR";
}
```

| Param            | Required | Default                                                              | Meaning |
|------------------|----------|----------------------------------------------------------------------|---------|
| `nixpkgs`        | yes      | —                                                                    | The consumer's `nixpkgs` flake input. Passed in so the consumer controls pinning. |
| `skillName`      | yes      | —                                                                    | String. Becomes the skill's directory name (e.g. `"garnix-ci"`). |
| `src`            | yes      | —                                                                    | Path to the skill directory (typically `./.` from the per-skill `flake.nix`). |
| `systems`        | no       | `[ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ]` | Systems to build for. |
| `description`    | no       | `"Claude Code skill: ${skillName}"`                                  | `meta.description` on the skill derivation. |
| `version`        | no       | `"0.1.0"`                                                            | Skill package version. |
| `extraDirs`      | no       | `[ ]`                                                                | Additional top-level directories from `src` to ship into the install. Use for upstream skills with non-standard layouts (e.g. `[ "agents" "assets" "eval-viewer" ]` for `anthropics/skills`' `skill-creator`). Missing dirs are silently ignored. |
| `installRoot`    | no       | `"$HOME/.claude/skills"`                                             | Default install target. **Raw shell expression** — `$HOME` is expanded at runtime. |
| `envVarOverride` | no       | `"CLAUDE_SKILLS_DIR"`                                                | Name of an env var the user can set to override `installRoot`. |

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
nix run .                           # preview every skill (read-only)
nix run .#install                   # install every skill — symlinks + GC roots
nix run .#install -- --profile      # via nix profile
nix run .#uninstall -- <name>       # remove one skill by name
nix run .#reap                      # remove broken managed entries
nix run .#reconcile                 # install declared set, sweep strays
nix build .#all                     # symlinkJoin'd derivation for all skills
nix build .#<skill-name>            # single skill derivation
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
  name           = "claude-skills-all";
  installRoot    = "$HOME/.claude/skills";
  envVarOverride = "CLAUDE_SKILLS_DIR";
}
```

| Param            | Required | Default                                                              | Meaning |
|------------------|----------|----------------------------------------------------------------------|---------|
| `nixpkgs`        | yes      | —                                                                    | The consumer's `nixpkgs` flake input. |
| `skillsDir`      | yes      | —                                                                    | Path to a directory whose subdirectories are individual skills. A subdir is a "skill" iff it contains a `SKILL.md`. |
| `systems`        | no       | `[ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ]` | Systems to build for. |
| `name`           | no       | `"claude-skills-all"`                                                | Aggregate derivation name (also used as the install/preview app suffix). |
| `installRoot`    | no       | `"$HOME/.claude/skills"`                                             | Default install target. **Raw shell expression** — `$HOME` is expanded at runtime. |
| `envVarOverride` | no       | `"CLAUDE_SKILLS_DIR"`                                                | Env var that overrides `installRoot`. |

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
- Subdir name becomes the skill name (must match the `name` field in
  `SKILL.md`'s frontmatter for the agent to load it).
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
└── <extraDirs[*]>/   # any directories listed in `extraDirs`, copied recursively if present
```

Everything else in `src` is ignored — including `flake.nix`, `flake.lock`,
hidden dotfiles, and any other top-level files. If a skill ships content in
non-standard top-level directories (e.g. `agents/`, `assets/`), name them in
`extraDirs` so they get shipped alongside the standard surface. Loose
top-level files outside that whitelist are still ignored.

The expected source layout matches the [Anthropic agent-skill format][skills]:

```
my-skill/
├── SKILL.md          # required — frontmatter + instructions
├── references/       # optional — long-form docs
└── scripts/          # optional — executable helpers
```

The `SKILL.md` frontmatter `name` field should match `skillName`.

## Install behavior

`nix run .#install` has two modes.

### Default: symlink + GC root

The Nix-native install. Three things happen:

1. **User-facing symlink.**
   `${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/<skillName>` is created as a
   symlink to `<store-path>/share/claude-skills/<skillName>`. Claude Code
   follows it transparently.
2. **Per-user GC root.**
   `/nix/var/nix/gcroots/per-user/$USER/claude-skill-<skillName>` is created as
   a symlink to the store derivation. This protects the store path from
   `nix-store --gc`. Override the gcroots dir with `NIX_GCROOTS_DIR` (used by
   the test suite; rarely useful in practice).
3. **Aggregate lock entry.**
   An entry is upserted into
   `${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/.flake-skills-lock.json`
   summarizing what was installed (provenance from the per-skill sentinel +
   the resolved `storePath` + an `installedAt` timestamp). See
   [Lock file](#lock-file) below.

The user-facing symlink is read-only by virtue of pointing into the store. To
**upgrade** a skill, re-run `nix run .#install`: the symlink is replaced
atomically, the new store path becomes the GC root, the old path becomes
GC-eligible, and the lock entry is refreshed.

### `--profile`: via `nix profile install`

If you want skills to participate in the `nix profile` machinery
(`list`/`upgrade`/`rollback`/`remove`):

```sh
nix run .#install -- --profile
```

This calls `nix profile install <store-path>`, then symlinks
`~/.claude/skills/<skillName>` into `~/.nix-profile/share/claude-skills/`.
GC protection comes from the profile itself; no separate GC root. The
aggregate lock is updated the same way as in symlink mode.

To **upgrade** in this mode: `nix profile upgrade --regex 'claude-skill-<name>'`.

## Uninstall behavior

```sh
nix run .#uninstall                  # single-skill flake: removes that skill
nix run .#uninstall -- <name>        # multi-skill flake: removes one by name
nix run .#uninstall -- alpha beta    # multiple at once
```

Removes all three install-side artifacts:

- the user-facing symlink at `$target_root/<name>`,
- the per-user GC root at `$gcroots_dir/claude-skill-<name>`,
- the entry in `$target_root/.flake-skills-lock.json`.

It refuses to touch entries it can't confidently identify as managed by this
flake-skills lineage (the sentinel must say `managedBy=<this lineage>`, or — if
the symlink target has been GC'd — a same-named GC root must exist as a
naming-convention fallback). A user's hand-rolled `~/.claude/skills/foo`
directory is therefore safe even if `foo` happens to match a flake-skills
skill name.

For `--profile`-mode installs, `nix run .#uninstall` removes the user-facing
symlink + lock entry, but the entry stays in the Nix profile. Run
`nix profile remove` separately to drop it from the profile.

## Lock file

`$target_root/.flake-skills-lock.json` is a single-file index of every skill
this flake-skills lineage has installed under `$target_root`. Same data as
the per-skill sentinels (`$target_root/<name>/.flake-skills-managed.json`),
indexed by name so you can `cat` it for an overview:

```json
{
  "schemaVersion": 1,
  "skills": {
    "garnix-ci": {
      "schemaVersion": 1,
      "managedBy": "github:nhooey/flake-skills",
      "managedByRev": "abc123...",
      "managedByDirty": false,
      "managedByNarHash": "sha256-...",
      "skillName": "garnix-ci",
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

The defaults target Claude Code's `~/.claude/skills/` directory. To support
[Codex][codex], [Cursor][cursor], or any other agent that adopts the same
skill format, retarget via `installRoot` and `envVarOverride`:

```nix
flake-skills.lib.mkSkillFlake {
  inherit nixpkgs;
  skillName      = "my-skill";
  src            = ./.;
  installRoot    = "$HOME/.codex/skills";
  envVarOverride = "CODEX_SKILLS_DIR";
}
```

[codex]: https://github.com/openai/codex
[cursor]: https://www.cursor.com/

## Stability

The public surface is `lib.mkSkillFlake` and `lib.mkAllSkillsFlake`.
Consumers should pin via `flake.lock`. If a breaking change is ever needed,
a new entry point will be added (e.g. `lib.v2.mkSkillFlake`) rather than
mutating an existing function in place.

## Canonical consumer

[`nhooey/skills-nix`][skills-nix] uses `mkAllSkillsFlake` for its top-level
flake and `mkSkillFlake` for each per-skill flake. It is the reference
example of the multi-skill aggregation pattern.

## License

[Apache-2.0](LICENSE)
