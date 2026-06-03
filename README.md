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
[nix-systems]: https://github.com/nix-systems/default

## Single-skill: `mkSkillFlake`

A per-skill `flake.nix` is ten lines:

```nix
# skills/my-skill/flake.nix
{
  description = "my-skill: Claude Code skill for X";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-skills = {
      url = "github:nhooey/flake-skills";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { nixpkgs, flake-skills, ... }:
    flake-skills.lib.mkSkillFlake {
      inherit nixpkgs;
      skillName = "my-skill";
      src = ./.;
    };
}
```

That gives you, for each system in the default
[`nix-systems/default`][nix-systems] set:

```sh
nix run .#preview   -- --scope=personal              # preview at $HOME/.claude/skills/
nix run .#install   -- --scope=personal              # install at $HOME/.claude/skills/
nix run .#install   -- --scope=project               # install at <repo-root>/.claude/skills/
nix run .#install   -- --scope=custom --root=/tmp/x  # install at the named path
nix run .#install   -- --scope=personal --profile    # via `nix profile install`
nix run .#uninstall -- --scope=personal              # remove the skill
nix run .#reap      -- --scope=personal              # remove broken managed entries
nix run .#purge     -- --scope=personal              # remove ALL this lineage's skills (teardown)
nix build .#my-skill                                 # produce $out/share/claude-skills/my-skill/
```

`--scope` is **required** on every install/uninstall/reap/purge/reconcile/preview
invocation — there is no implicit default. See
[Install scope](#install-scope) for the resolver semantics.

### `mkSkillFlake` API

```nix
flake-skills.lib.mkSkillFlake {
  nixpkgs        = <flake input>;
  skillName      = "my-skill";
  src            = ./.;
  # optional:
  systems        = import systems;  # default: the `nix-systems/default` input; override per "Overriding the target systems"
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
| `systems`     | no       | `import systems` — the [`nix-systems/default`][nix-systems] input | Systems to build for. Override the `systems` input or pass an explicit list — see [Overriding the target systems](#overriding-the-target-systems). |
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
    purge     = { type = "app"; program = "<purge>"; };
  });
}
```

### Overriding the target systems

By default every builder fans out over the [`nix-systems/default`][nix-systems]
set — the library never hardcodes a platform list. Retarget it without
forking by pointing flake-skills' `systems` input at your own:

```nix
inputs = {
  systems.url = "github:nix-systems/x86_64-linux";   # or any nix-systems fork / subset
  flake-skills = {
    url = "github:nhooey/flake-skills";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.systems.follows = "systems";              # flake-skills tracks your set
  };
};
```

Or pass `systems` directly at the call site — `import systems` from your own
input, or an explicit list:

```nix
flake-skills.lib.mkSkillFlake {
  inherit nixpkgs;
  systems   = import systems;   # your own nix-systems input (a list literal also works)
  skillName = "my-skill";
  src       = ./.;
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
    flake-skills = {
      url = "github:nhooey/flake-skills";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
  systems        = import systems;  # default: the `nix-systems/default` input; override per "Overriding the target systems"
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
| `systems`    | no       | `import systems` — the [`nix-systems/default`][nix-systems] input | Systems to build for. Override the `systems` input or pass an explicit list — see [Overriding the target systems](#overriding-the-target-systems). |
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
    purge     = { type = "app"; program = "<purge>"; };
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

## Consumer-side prefixing: `withNamePrefix`

`renameFn` runs at the *producer's* eval time — once a skill flake has
emitted its packages, the name is frozen in the store path. A downstream
consumer pulling someone else's skill pack as a flake input has no way
to rename it without rebuilding the upstream source.

`lib.withNamePrefix` is the consumer-side escape hatch. It takes a
pre-built skill (or skills env), copies its contents under a
`<prefix>-<oldName>` directory, rewrites `SKILL.md` frontmatter `name:`
and the `.flake-skills-managed.json` sentinel `skillName`, and refreshes
passthru so the wrapped drv behaves like a first-class `mkSkill` output
everywhere downstream (home-manager activation, installer, reconcile,
`mkSkillsEnv`). A `-` separator is auto-inserted between prefix and
old name; chaining wrappers compounds the prefix.

```nix
# Wrap a single skill:
flake-skills.lib.withNamePrefix {
  pkgs       = nixpkgs.legacyPackages.${system};
  namePrefix = "gstack";
  skill      = inputs.someones-skills.packages.${system}.skill-foo;
}
# → drv with passthru.flakeSkillName = "gstack-foo"

# Wrap a skills env (every member gets the same prefix):
flake-skills.lib.withNamePrefix {
  pkgs       = nixpkgs.legacyPackages.${system};
  namePrefix = "superpowers";
  skill      = flake-skills.lib.mkSkillsEnv {
    inherit pkgs;
    name   = "their-pack";
    skills = [ inputs.someones-skills.packages.${system}.skill-foo
               inputs.someones-skills.packages.${system}.skill-bar ];
  };
}
# → env whose `flakeSkillsEnv` members are individually prefix-wrapped:
#   superpowers-foo, superpowers-bar
```

| Param        | Required | Default | Meaning |
|--------------|----------|---------|---------|
| `pkgs`       | yes      | —       | Nixpkgs instance for the target system. Same shape as `mkSkillsEnv`'s `pkgs`. |
| `namePrefix` | yes      | —       | Non-empty string. Must match `^[a-z0-9][a-z0-9-]*$`. The combined `<prefix>-<oldName>` is asserted against Claude Code's `^[a-z0-9-]{1,64}$` rule per member, so an over-long prefix fails `nix flake check`. |
| `skill`      | yes      | —       | Either a single skill drv (`passthru.isFlakeSkill`) or a skills env drv (`passthru.isFlakeSkillsEnv`). Anything else throws. |

What the wrapper preserves from the upstream sentinel:
`originalSkillName`, `managedBy`/`managedByRev`/`managedByDirty`/
`managedByNarHash`, `version`, `schemaVersion`. Only `skillName` is
rewritten. Traceability back to the upstream lineage survives
re-prefixing.

## Marketplace / aggregation

A "marketplace" flake pulls several upstream skill flakes, optionally
cherry-picks and namespace-prefixes them, and exposes a merged package
set + install apps + a devshell that installs everything. The five
helpers below promote that logic out of the consumer (which used to
hand-roll it against the private `lib/internal.nix` module).

If you only need the top-level result, reach for
[`mkAggregateSkillsFlake`](#mkaggregateskillsflake) — it composes the
other four. They are also exposed individually for finer control.

> Every helper here takes `{ nixpkgs, system, … }` (single-system) or
> `{ nixpkgs, systems, … }` (whole-flake) and derives
> `pkgs = nixpkgs.legacyPackages.${system}` internally — matching every
> builder in this library. The older `withNamePrefix` stays `pkgs`-based.

### `mkInstaller` — installer over an arbitrary skill set

The single primitive that used to force consumers to import
`lib/internal.nix`. Builds a `bin/install-<appName>` over an
already-built `[ { name; drv; } ]` list, resolving the agent profile for
you.

```nix
flake-skills.lib.mkInstaller {
  inherit nixpkgs system;
  appName = "my-pack";                 # → bin/install-my-pack
  skills  = [ { name = "foo"; drv = fooDrv; }
              { name = "bar"; drv = barDrv; } ];
  agent   = "claude-code";             # optional; resolved to a profile
}
# → installer derivation
```

`lib.resolveAgentProfile { nixpkgs; agent; }` and the pure-data
`lib.agentProfiles` are exposed too, for callers that need the profile
directly.

### `withNamePrefixSource` — prefix-wrap every skill in a source flake

The plural of [`withNamePrefix`](#consumer-side-prefixing-withnameprefix).
Prefix-wraps every skill package a source exposes, returning
`[ { name; drv; } ]` records keyed by the prefixed name.

```nix
flake-skills.lib.withNamePrefixSource {
  inherit nixpkgs system;
  namePrefix    = "superpowers";
  source        = inputs.superpowers;  # has .packages.<system>
  packagePrefix = "skill-";            # which keys count as skills
}
# → [ { name = "superpowers-<old>"; drv = wrappedDrv; } … ]
```

Filtering by `packagePrefix` also drops the source's `default` /
`<name>-all` aggregate keys, so only real skills are wrapped.

### `mkPrefixedInstaller` — wrap a source, then build its installer

`withNamePrefixSource` + `mkInstaller`. The source's own installer was
sealed against un-prefixed names at build time, so a fresh one is built
over the wrapped set.

```nix
flake-skills.lib.mkPrefixedInstaller {
  inherit nixpkgs system;
  source     = inputs.superpowers;
  namePrefix = "superpowers";
  # packagePrefix ? "skill-", agent ? "claude-code",
  # appName ? "agent-skills-${namePrefix}-all"
}
# → installer derivation over the prefix-wrapped source
```

### `installCommandFor` — the `"<bin> <args>"` install string

Independent of any devshell, so a consumer can assemble its own startup
script / Makefile / app. Covers prefix-or-not and all-or-subset.

```nix
flake-skills.lib.installCommandFor {
  inherit nixpkgs system;
  source = inputs.skills-nix;
  prefix ? null;        # null → the source's own install app
  skills ? null;        # null → install all
  scope  ? "project";   # personal | project | custom
}
# → "<installer-bin> --scope=project [name …]"
```

### `mkAggregateSkillsFlake`

The whole marketplace in one call. `mkAllSkillsFlake` handles one local
`skillsDir`; this folds that optional base together with a list of
upstream source flakes (each optionally prefixed) into one package set,
a combined app suite over the union, and a devshell-ready
**reconcile** script.

```nix
let
  agg = flake-skills.lib.mkAggregateSkillsFlake {
    inherit nixpkgs;
    skillsDir     = ./skills;            # optional local skills (base)
    packagePrefix = "agent-skill-";
    sources = [
      { source = skills-git; }                              # all skills
      { source = skills-nix; skills = [ "nix-flakes" ]; }   # subset
      { source = skill-creator; prefix = "anthropic"; }     # namespaced
      { source = superpowers;   prefix = "superpowers"; }
    ];
  };
in {
  packages.${system} = agg.packages.${system};
  apps.${system}     = agg.apps.${system};
  devShells.${system}.default = pkgs.mkShell {
    # Declarative: converge .claude/skills/ to exactly the union —
    # install missing, update changed, sweep skills a source dropped
    # or renamed.
    shellHook = agg.reconcileScript system;
  };
}
```

It returns:

| Field            | Shape                  | Meaning |
|------------------|------------------------|---------|
| `packages`       | `forAllSystems` attrset | base per-skill keys + base `default`/`<name>-all` aggregates + every source's `packagePrefix`-keys, merged. Sources contribute **only** skill keys — their own `default`/aggregate keys are filtered out, so they can't clobber the base aggregate. |
| `apps`           | `forAllSystems` attrset | the combined `install`/`uninstall`/`preview`/`reap`/`purge`/`reconcile` apps over the **union** (base + every source), all under `<verb>-${name}`. `reconcile` converges the target to the whole union; `purge` tears the whole lineage's slice out of a scope (see [Retiring flake-skills](#retiring-flake-skills)). |
| `reconcileScript`| `system → string`       | the declarative dev-shell one-liner: `reconcile-${name} --scope=project`. A single command (one owner of the target). |

`sources` entries are `{ source; skills ? null; prefix ? null; }`:
`skills = null` installs everything (a list cherry-picks);
`prefix = null` merges the source's packages verbatim, otherwise every
skill is re-prefixed via `withNamePrefixSource`. `packagePrefix` is
flake-wide (one value for filtering every source's keys and for re-keying
the merged output).

For the wrong ways to wire this up — `nix run <input>#install` defeating a
`follows`, a `packagePrefix` that matches no source keys, a verbatim package
merge that clobbers `default` — see
[Pitfalls](#pitfalls--wrong-ways-to-install).

#### Declarative convergence (`reconcileScript`)

A dev shell that installs each source with its own `install` line
re-converges by adding only: `install` adds or updates *its own*
symlinks, so when a skill is **renamed or dropped** from the
declared set its stale symlink lingers — e.g. after superpowers skills
gained a `superpowers-` prefix, the old un-prefixed `brainstorming` would
survive next to the new `superpowers-brainstorming`. A per-source
`reconcile` can't fix this either: every source shares one `flake-skills`
lineage, so any one source's reconcile would sweep the *other* sources'
skills as strays.

`reconcileScript` solves this because the aggregate already computes the
union of every declared skill and installs through a single combined
installer that **owns** the target. Its `reconcile` converges the target
to exactly that union — install missing, update changed, sweep the
renamed/removed strays — so the dev shell is a pure function of the flake
inputs. No sibling is ever mistaken for a stray, because every sibling is
in the declared union.

**Scoped ownership.** Each install/reconcile tags its lock entries with
the aggregate's `name` (`installedBy`), and `reconcile` sweeps only strays
bearing *its own* `name`. So multiple aggregates (or a hand-rolled
installer) can share one `.claude/skills/`, each declaratively owning its
own slice without sweeping the others'.

### `mkCombination`

A **combination** is a curated, cross-cutting union of skills that is, by
construction, *both* directly consumable *and* re-composable as a source.
It is a thin wrapper over [`mkAggregateSkillsFlake`](#mkaggregateskillsflake):
the aggregate's `packages` / `apps` / `reconcileScript` pass through
verbatim, plus one home-manager `mkSkillsEnv` `env` per system over the
aggregate's skills.

```nix
let
  authoring = flake-skills.lib.mkCombination {
    inherit nixpkgs;
    name    = "skillspkgs-authoring";   # reconcile ownership appName
    envName = "agent-skills-authoring"; # home-manager env package name
    sources = [
      { source = skills-git; }
      { source = skill-creator; prefix = "anthropic"; }
    ];
  };
in {
  packages.${system}.authoring-env = authoring.env.${system};
  devShells.${system}.default = pkgs.mkShell {
    shellHook = authoring.reconcileScript system;
  };
}
```

Because `packages` is preserved, `{ source = authoring; }` splices the
*whole* combination into another `mkAggregateSkillsFlake` — prefixes
intact — instead of forcing a consumer to re-derive its source list by
hand. It returns `{ packages; apps; reconcileScript; env; }`, all
system-parametric (`env.<sys>` is the bundled home-manager env). `envName`
defaults to `name`; `packagePrefix`, `agent`, and `systems` match
`mkAggregateSkillsFlake`'s defaults.

### Project-scope dev-shell skills: the `skills-devshell` sub-flake

To install a curated skill set into a repo's dev shell at project scope on
`nix develop`, **don't** add the skill-source flakes (`skills-git`, a
combination, …) as inputs of your main flake — your main flake's inputs are
inherited by everything that consumes it, so a library would drag its
dev-only skill sources into every downstream lock. Instead isolate them in a
dedicated **`skills-devshell/` sub-flake** with its own `flake.lock`.

The convention: the sub-flake declares the skill sources as *its own*
inputs, builds a [`mkCombination`](#mkcombination) over them (one reconcile
owner for the whole set), and outputs the reconcile one-liner as **text,
keyed by system** — not a `system → string` function — so the root just
splices a string and never has to know it is a reconcile script:

```nix
# skills-devshell/flake.nix (outputs)
flake.reconcileScript = forSystems (system: combo.reconcileScript system);
#   forSystems = nixpkgs.lib.genAttrs (import systems);
```

The main flake then needs exactly one input and one startup line:

```nix
inputs.skills-devshell = {
  url = "path:./skills-devshell";
  inputs.nixpkgs.follows = "nixpkgs";
};
# … per system, in the dev shell (numtide/devshell shown; plain mkShell uses shellHook):
devshell.startup.install-skills.text = inputs.skills-devshell.reconcileScript.${system};
```

The input is dev-shell-only and lazily evaluated, so it never affects the
library's actual API. This flake's own
[`skills-devshell/flake.nix`](skills-devshell/flake.nix) is the canonical
example — it combines the `skills-git` pack with skillspkgs' `authoring`
combination. **Downstream repos should follow this same convention** when
installing skills into their dev shells at project scope.

## Install scope

Every install/uninstall/reap/purge/reconcile/preview invocation **must** declare
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

## Pitfalls — wrong ways to install

The sections above show the correct forms. This one is the inverse: the
wrong ways, each a flat "don't / do instead" rule. Several of these fail
**silently** — they install nothing, or install something that decays
later — so they are worth stating explicitly. Roughly ordered by how
likely each is to bite and how quiet the failure is.

### 1. Don't `nix run <input>#install` on a `follows`-pinned input

`nix run <flakeref>#install` evaluates `<flakeref>` as a standalone flake
using **its own** `flake.lock`. The `inputs.<x>.follows` you declared only
applies when you reach the input through *your* evaluation. So
`nix run ${superpowers}#install` builds an installer against superpowers'
pinned `flake-skills`, not yours — defeating the `follows` and risking a
double-evaluated, mismatched toolchain.

**Do instead:** reference the already-resolved app path from your own
outputs — `<input>.apps.${system}.install.program` — or let
[`installCommandFor`](#installcommandfor--the-bin-args-install-string) /
[`mkAggregateSkillsFlake`](#mkaggregateskillsflake)'s `installScript` do it
for you (they emit exactly that path). This is *the* reason `installScript`
exists.

### 2. Don't hand-symlink or `cp` a store path into the skills dir

`ln -s /nix/store/…-skill-foo ~/.claude/skills/foo` (or copying it) skips
the two things the installer does for you: the **per-user GC root** (so the
next `nix-store --gc` can delete the store path out from under your symlink)
and the **`.flake-skills-lock.json` entry** (so `uninstall` / `reap` /
`reconcile` can't see it as managed and refuse to touch it).

**Do instead:** `nix run .#install -- --scope=…` (or the aggregate
`installScript`), which creates symlink + GC root + lock entry atomically.
See [Default: symlink + GC root](#default-symlink--gc-root).

### 3. Don't import `lib/internal.nix` to build an installer

`internal.nix` is private and uncontracted — its signatures can change
between releases with no migration note. Reaching into it
(`internal.mkInstaller`, `internal.resolveAgentProfile`) is the
pre-marketplace hack the public helpers were created to retire.

**Do instead:** use
[`lib.mkInstaller`](#mkinstaller--installer-over-an-arbitrary-skill-set),
`lib.resolveAgentProfile`, `lib.agentProfiles`, or the higher-level
marketplace helpers. Only the `lib.*` surface is stable.

### 4. Don't set `prefix` on a source whose keys don't match `packagePrefix`

When you prefix a source,
[`withNamePrefixSource`](#withnameprefixsource--prefix-wrap-every-skill-in-a-source-flake)
filters that source's package keys by the **flake-wide** `packagePrefix`.
If the source exposes its skills under a different prefix (e.g. its keys are
`skill-*` but your `packagePrefix` is `agent-skill-`), the filter matches
**zero** keys and you get an installer that installs nothing — **no error**.

**Do instead:** confirm the source's actual package-key prefix
(`nix eval <source>#packages.<system> --apply builtins.attrNames`) and set
the flake-wide `packagePrefix` to match it.

### 5. Don't merge a source's `packages` verbatim into your package set

`base.packages.${system} // source.packages.${system}` drags in the
source's `default` and `<name>-all` aggregate keys; a later source's
`default` silently overwrites your base aggregate's `default`.

**Do instead:** filter to `packagePrefix` keys — which is exactly what
[`mkAggregateSkillsFlake`](#mkaggregateskillsflake) does on every source —
so aggregate keys never leak into the merge.

### 6. Don't rely on `--scope` having a default

There is no implicit scope — every `install` / `uninstall` / `reap` /
`reconcile` / `preview` invocation must pass `--scope`. A missing scope
hard-errors; `--root` is only valid with `--scope=custom`; `--scope=project`
hard-errors if no `.git/` or `flake.nix` marker is found walking up from
`$PWD`.

**Do instead:** always state the scope explicitly at the call site. See
[Install scope](#install-scope).

### 7. Don't hand-edit `.flake-skills-lock.json` or delete a GC root manually

`uninstall` identifies managed entries via the sentinel + lock + GC root.
Hand-editing the lock or `rm`-ing the GC root breaks that detection, leaving
orphaned symlinks `uninstall` will then refuse to remove.

**Do instead:** `nix run .#uninstall -- --scope=… <name>` to remove, `reap`
to clear broken managed entries, `reconcile` to converge to a declared set.
See [Uninstall behavior](#uninstall-behavior).

### 8. Don't `nix profile install` the skill store path directly

`nix profile install <store-path>` registers the derivation but never
creates the user-facing `~/.claude/skills/<name>` symlink, so the agent
never sees the skill.

**Do instead:** `nix run .#install -- --scope=… --profile`, which both
`nix profile install`s and creates the symlink (GC protection comes from the
profile). See [`--profile`](#--profile-via-nix-profile-install).

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

## Retiring flake-skills

Dropping a skill from a declared set is self-healing — `reconcile` owns the
entry by `appName` and sweeps it on the next run. Deleting the hook itself
is not: nothing tagged with its `appName` runs again, so its skills orphan.
To retire cleanly, clear the scope first. Either converge to empty while the
hook still exists (set `skills = [ ]` / `sources = [ ]`, keep it enabled —
in home-manager keep `enable = true;` and `switch` *before* deleting the
block, since `config` is gated on `enable`), or, once no hook is left, run
`purge`:

```sh
nix run github:nhooey/flake-skills#purge -- --scope=personal   # clears ~/.claude/skills/
nix run github:nhooey/flake-skills#purge -- --scope=project    # clears <repo>/.claude/skills/
nix run .#purge -- --scope=project --dry-run                   # list what would go; change nothing
nix run .#purge -- --scope=personal --yes                      # skip the confirmation prompt
```

`purge` removes every entry this lineage (`managedBy`) installed under the
scope — live or broken, any `appName`, no declared set or names needed — and
runs transiently off the bare flake when nothing is installed locally. It
leaves other lineages and hand-rolled dirs alone, and confirms before
removing (`--dry-run`/`--yes` skip the prompt; non-interactive without either
refuses).

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
      "installedAt": "2026-04-27T12:34:56Z",
      "installedBy": "agent-skills-all"
    }
  }
}
```

The lock is **descriptive, not authoritative**: install / reconcile / reap /
purge / uninstall rebuild it from the symlinks + sentinels, so editing it by hand has
no lasting effect. The source of truth is still the symlink + GC root + the
sentinel inside each store path.

`installedBy` is the one exception — it records the installer `appName` that
owns the entry, and a scoped `reconcile` consults it to sweep only the strays
it owns (see [Declarative convergence](#declarative-convergence-reconcilescript)).
It is written by every `mkInstaller` / `mkReconcile`-built app; an entry with
no recorded owner (a stray with no lock entry) falls back to the lineage rule.

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
