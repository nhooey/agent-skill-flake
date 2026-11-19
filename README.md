# agent-skill-flake

A tiny Nix flake providing two functions for building installable Nix flakes
from [Claude Code agent-skill][skills] directories:

- **`lib.mkSkillFlake`** — turn a single skill directory into a flake.
- **`lib.mkAllSkillsFlake`** — turn a directory of skills into one
  multi-skill flake (auto-discovery + aggregate install/preview).

Use these to skip the boilerplate of wiring up `packages` / `apps` /
install / preview by hand. The canonical multi-skill consumer is
[`nhooey/nix-skills`][nix-skills].

[skills]: https://www.anthropic.com/engineering/agent-skills
[nix-skills]: https://github.com/nhooey/nix-skills
[nix-systems]: https://github.com/nix-systems/default

## Single-skill: `mkSkillFlake`

A per-skill `flake.nix` is ten lines:

```nix
# skills/my-skill/flake.nix
{
  description = "my-skill: Claude Code skill for X";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { nixpkgs, agent-skill-flake, ... }:
    agent-skill-flake.lib.mkSkillFlake {
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
nix run .#install   -- --scope=project               # install at <repo-root>/.agents/skills/
nix run .#install   -- --scope=custom --root=/tmp/x  # install at the named path
nix run .#install   -- --scope=personal --profile    # via `nix profile install`
nix run .#uninstall -- --scope=personal              # remove the skill
nix run .#reap      -- --scope=personal              # remove broken managed entries
nix run .#check     -- --scope=personal              # report links without this target's GC root
nix run .#purge     -- --scope=personal              # remove ALL this lineage's skills (teardown)
nix build .#my-skill                                 # produce $out/share/claude-skills/my-skill/
```

`--scope` is **required** on every install/uninstall/reap/purge/reconcile/preview
invocation — there is no implicit default. See
[Install scope](#install-scope) for the resolver semantics.

### `mkSkillFlake` API

```nix
agent-skill-flake.lib.mkSkillFlake {
  nixpkgs        = <flake input>;
  skillName      = "my-skill";
  src            = ./.;
  # optional:
  systems        = import systems;  # default: the `nix-systems/default` input; override per "Overriding the target systems"
  description    = "Claude Code skill: my-skill";
  version        = "0.1.0";
  extraDirs      = [ ];           # ship additional top-level dirs alongside SKILL.md/references/scripts
  extraFiles     = [ ];           # ship additional top-level files (shell globs evaluated in `src`)
  scriptInputs   = pkgs: [ ];     # tools the scripts/ executables find on PATH (see "Build behavior")
  agent          = "claude-code"; # selects an agent profile (see "Targeting other agents")
  # rename (optional) — see "Renaming & name collisions" below:
  renameFn       = ctx: ctx.name;            # identity (no rename)
  source         = null;                     # skill's origin repo, for ctx.source.* / namespaceFn
  namespaceFn    = ctx: ctx.source.owner;    # owner segment in the package key
  packagePrefix  = null;                     # category prefix, default "agent-skill-"
  packageName    = null;                     # defaults to "<packagePrefix><namespace>-<effectiveName>"
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
| `scriptInputs` | no      | `pkgs: [ ]`                                                          | Function from the system's `pkgs` to the packages the skill's scripts run, such as `pkgs: [ pkgs.babashka ]`. Each executable directly in `scripts/` finds their `bin/` on PATH; see [Build behavior](#build-behavior). |
| `agent`       | no       | `"claude-code"`                                                      | Which agent's filesystem layout to target. See [Targeting other agents](#targeting-other-agents). Throws at eval if the name isn't a known profile. |
| `renameFn`    | no       | `ctx: ctx.name`                                                      | Formula deriving the effective name from a context attrset. See [Renaming & name collisions](#renaming--avoiding-claude-code-name-collisions). |
| `source`      | no       | `null`                                                               | The skill's origin repo, supplied from your flake `self` (+ owner/repo). The default `namespaceFn` reads `ctx.source.owner` from it; also feeds `renameFn`'s `ctx.source.*`. |
| `namespaceFn` | no       | `ctx: ctx.source.owner`                                             | Owner segment spliced into the package key. A non-empty string → `<packagePrefix><segment>-<effectiveName>`; `""` omits it; `null` (default with no derivable owner) is a hard eval error. Touches only the key, not the installed name. |
| `packagePrefix` | no     | `null` → `"agent-skill-"`                                           | Category prefix on the package key, before the namespace segment. |
| `packageName` | no       | `null` → `"<packagePrefix><namespace>-<effectiveName>"`             | Override the `packages.<system>.<key>` attribute name (wins over `packagePrefix`/`namespaceFn`). |

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
forking by pointing agent-skill-flake's `systems` input at your own:

```nix
inputs = {
  systems.url = "github:nix-systems/x86_64-linux";   # or any nix-systems fork / subset
  agent-skill-flake = {
    url = "github:nhooey/agent-skill-flake";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.systems.follows = "systems";              # agent-skill-flake tracks your set
  };
};
```

Or pass `systems` directly at the call site — `import systems` from your own
input, or an explicit list:

```nix
agent-skill-flake.lib.mkSkillFlake {
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
  description = "nix-skills: Claude Code skills marketplace";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { nixpkgs, agent-skill-flake, ... }:
    agent-skill-flake.lib.mkAllSkillsFlake {
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
nix run .#check     -- --scope=personal                 # report links without this target's GC root
nix run .#reconcile -- --scope=personal                 # install declared set, sweep strays
nix build .#all                                         # symlinkJoin'd derivation for all skills
nix build .#<skill-name>                                # single skill derivation
```

The aggregate installer creates one symlink and one GC root per skill, using
exactly the same machinery as the single-skill installer.

### `mkAllSkillsFlake` API

```nix
agent-skill-flake.lib.mkAllSkillsFlake {
  nixpkgs        = <flake input>;
  skillsDir      = ./skills;
  # optional:
  systems        = import systems;  # default: the `nix-systems/default` input; override per "Overriding the target systems"
  name           = null;                     # default: "agent-skills-<owner>-all"
  agent          = "claude-code"; # selects an agent profile (see "Targeting other agents")
  extraDirs      = [ ];           # additional top-level dirs (applied to every discovered skill)
  extraFiles     = [ ];           # additional top-level files (shell globs; applied to every discovered skill)
  scriptInputs   = { };           # per skill: { my-skill = pkgs: [ pkgs.babashka ]; }
  # rename (optional) — see "Renaming & name collisions" below:
  renameFn       = ctx: ctx.name;            # identity (no rename)
  source         = null;                     # skills' origin repo, for ctx.source.* / namespaceFn
  namespaceFn    = ctx: ctx.source.owner;    # owner segment in each package key
  packagePrefix  = null;                     # category prefix, default "agent-skill-"
}
```

| Param        | Required | Default                                                              | Meaning |
|--------------|----------|----------------------------------------------------------------------|---------|
| `nixpkgs`    | yes      | —                                                                    | The consumer's `nixpkgs` flake input. |
| `skillsDir`  | yes      | —                                                                    | Path to a directory whose subdirectories are individual skills. A subdir is a "skill" iff it contains a `SKILL.md`. |
| `systems`    | no       | `import systems` — the [`nix-systems/default`][nix-systems] input | Systems to build for. Override the `systems` input or pass an explicit list — see [Overriding the target systems](#overriding-the-target-systems). |
| `name`       | no       | `null` → `"agent-skills-<owner>-all"`                               | Aggregate package key + reconcile-ownership appName (`agent-skills-all` when the namespace is `""`). |
| `agent`      | no       | `"claude-code"`                                                      | Which agent's filesystem layout to target. See [Targeting other agents](#targeting-other-agents). |
| `extraDirs`  | no       | `[ ]`                                                                | Additional top-level directories to ship into each discovered skill's install. Applied uniformly to every skill; missing dirs are silently ignored. |
| `extraFiles` | no       | `[ ]`                                                                | Additional top-level files to ship at each discovered skill's install root. Each entry is a shell glob evaluated per-skill (nullglob: no-match silently dropped; directory matches are skipped). |
| `scriptInputs` | no     | `{ }`                                                                | Attrset from a discovered skill's name (before `renameFn`) to a `pkgs: [ … ]` function, as mkSkillFlake's `scriptInputs`. A name that matches no discovered skill is an eval error. |
| `renameFn`   | no       | `ctx: ctx.name`                                                      | Per-skill name formula. See [Renaming & name collisions](#renaming--avoiding-claude-code-name-collisions). |
| `source`     | no       | `null`                                                               | The skills' origin repo, supplied from your flake `self` (+ owner/repo). The default `namespaceFn` reads `ctx.source.owner`; also feeds `renameFn`'s `ctx.source.*`. |
| `namespaceFn`| no       | `ctx: ctx.source.owner`                                             | Owner segment spliced into every per-skill package key (and `agent-skills-<segment>-all`). Non-empty string → used; `""` omits it; `null` (default with no derivable owner) is a hard eval error. Touches only keys, not installed names. |
| `packagePrefix` | no    | `null` → `"agent-skill-"`                                           | Category prefix on each per-skill package key, before the namespace segment. |

Returns:

```nix
{
  packages = forAllSystems (system: {
    default                             = <symlinkJoin of every discovered skill>;
    "agent-skills-<owner>-all"          = <same aggregate>;
    "agent-skill-<owner>-${skillName1}" = <skill 1 derivation>;
    "agent-skill-<owner>-${skillName2}" = <skill 2 derivation>;
    # ...one owner-namespaced entry per discovered skill
  });
  # Per-skill drvs keyed by bare installed name (namespace-independent) —
  # pick skills for a pack with `mkSkillsEnv` without rebuilding keys.
  bySkillName = forAllSystems (system: {
    ${skillName1} = <skill 1 derivation>;
    ${skillName2} = <skill 2 derivation>;
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

`scripts/` is copied verbatim, so its scripts run against the user's
PATH. When they need a tool the user may not have, such as `bb` for a
Babashka program, name its package in `scriptInputs`: each executable
file directly in `scripts/` then finds their `bin/` first on PATH. A
shell script (a `bash`, `sh`, `dash`, `ksh` or `zsh` shebang) gets one
`PATH=…${PATH:+:$PATH}; export PATH` line after its shebang, so it keeps
its path and runs as `bash <script>` under any bash, macOS's 3.2 among
them. Any other executable is wrapped with `makeWrapper --prefix PATH`,
keeping its name, with the original beside it as `.<name>-wrapped`.
Files that aren't executable (libraries, data, tests) stay as they are.
The PATH change exists only in the Nix-built install: a skill copied from its source tree by other means runs its
scripts unwrapped, so such a script should say plainly what's missing
when a tool isn't on PATH.

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

Beside the content, `.agent-skill-flake-managed.json` (the sentinel)
records which agent-skill-flake built the skill, and its `contentHash`:
a hash of the skill folder's paths, file kinds and bytes, without the
sentinel, written `v1:sha256:<hex>`, where `v1:sha256` names how it was
computed. It is taken before `scriptInputs` and the build's shebang
patching write store paths into the scripts, and counts the script inputs
by name, so the same source gives the same hash under any nixpkgs. For the
same reason it doesn't see a `postInstall` or `postFixup` added with
`overrideAttrs`: two builds that differ only there record the same hash.
A project `reconcile` compares it to tell two copies of a skill apart (see
[A skill the personal scope already holds](#a-skill-the-personal-scope-already-holds)).

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
agent-skill-flake.lib.mkAllSkillsFlake {
  inherit nixpkgs;
  skillsDir = ./skills;
  source = {                       # from YOUR flake's `self` + owner/repo
    owner = "nhooey";
    repo  = "nix-skills";
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

  tooling = {                       # the agent-skill-flake lineage that built it
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
  `.agent-skill-flake-managed.json` sentinel as `originalSkillName`, so a
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
and the `.agent-skill-flake-managed.json` sentinel `skillName`, and refreshes
passthru so the wrapped drv behaves like a first-class `mkSkill` output
everywhere downstream (home-manager activation, installer, reconcile,
`mkSkillsEnv`). A `-` separator is auto-inserted between prefix and
old name; chaining wrappers compounds the prefix.

```nix
# Wrap a single skill:
agent-skill-flake.lib.withNamePrefix {
  pkgs       = nixpkgs.legacyPackages.${system};
  namePrefix = "gstack";
  skill      = inputs.someones-skills.packages.${system}.agent-skill-foo;
}
# → drv with passthru.flakeSkillName = "gstack-foo"

# Wrap a skills env (every member gets the same prefix):
agent-skill-flake.lib.withNamePrefix {
  pkgs       = nixpkgs.legacyPackages.${system};
  namePrefix = "superpowers";
  skill      = agent-skill-flake.lib.mkSkillsEnv {
    inherit pkgs;
    name   = "their-pack";
    skills = [ inputs.someones-skills.packages.${system}.agent-skill-foo
               inputs.someones-skills.packages.${system}.agent-skill-bar ];
  };
}
# → env whose `flakeSkillsEnv` members are individually prefix-wrapped:
#   superpowers-foo, superpowers-bar
```

| Param        | Required | Default | Meaning |
|--------------|----------|---------|---------|
| `pkgs`       | yes      | —       | Nixpkgs instance for the target system, one that has `replaceVars`. Same shape as `mkSkillsEnv`'s `pkgs`. |
| `namePrefix` | yes      | —       | Non-empty string. Must match `^[a-z0-9][a-z0-9-]*$`. The combined `<prefix>-<oldName>` is asserted against Claude Code's `^[a-z0-9-]{1,64}$` rule per member, so an over-long prefix fails `nix flake check`. |
| `skill`      | yes      | —       | Either a single skill drv (`passthru.isFlakeSkill`) or a skills env drv (`passthru.isFlakeSkillsEnv`). Anything else throws. |

What the wrapper preserves from the upstream sentinel:
`originalSkillName`, `managedBy`/`managedByRev`/`managedByDirty`/
`managedByNarHash`, `version`, `schemaVersion`. `skillName` is rewritten,
and `contentHash` becomes a hash of the upstream one and the new name, so
two wraps of the same skill under the same prefix compare equal whatever
nixpkgs built them. Traceability back to the upstream lineage survives
re-prefixing.

## Marketplace / aggregation

A "marketplace" flake pulls several upstream skill flakes, optionally
cherry-picks and namespace-prefixes them, and exposes a merged package
set + install apps + a devshell that installs everything. The five
helpers below give the consumer that logic without importing the private
`lib/internal.nix` module.

If you only need the top-level result, reach for
[`mkAggregateSkillsFlake`](#mkaggregateskillsflake) — it composes the
other four. They are also exposed individually for finer control.

> Every helper here takes `{ nixpkgs, system, … }` (single-system) or
> `{ nixpkgs, systems, … }` (whole-flake) and derives
> `pkgs = nixpkgs.legacyPackages.${system}` internally — matching every
> builder in this library. The older `withNamePrefix` stays `pkgs`-based.

### `mkInstaller` — installer over an arbitrary skill set

Builds a `bin/install-<appName>` over an
already-built `[ { name; drv; } ]` list, resolving the agent profile for
you.

```nix
agent-skill-flake.lib.mkInstaller {
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
agent-skill-flake.lib.withNamePrefixSource {
  inherit nixpkgs system;
  namePrefix    = "superpowers";
  source        = inputs.superpowers;  # has .packages.<system>
  packagePrefix = "agent-skill-";      # which keys count as skills (default)
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
agent-skill-flake.lib.mkPrefixedInstaller {
  inherit nixpkgs system;
  source     = inputs.superpowers;
  namePrefix = "superpowers";
  # packagePrefix ? "agent-skill-", agent ? "claude-code",
  # appName ? "agent-skills-${namePrefix}-all"
}
# → installer derivation over the prefix-wrapped source
```

### `installCommandFor` — the `"<bin> <args>"` install string

Independent of any devshell, so a consumer can assemble its own startup
script / Makefile / app. Covers prefix-or-not and all-or-subset.

```nix
agent-skill-flake.lib.installCommandFor {
  inherit nixpkgs system;
  source = inputs.nix-skills;
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
  agg = agent-skill-flake.lib.mkAggregateSkillsFlake {
    inherit nixpkgs;
    skillsDir     = ./skills;            # optional local skills (base)
    source        = { owner = "you"; };  # base owner → namespaces the base keys
    packagePrefix = "agent-skill-";
    sources = [
      { source = git-skills; }                              # all skills
      { source = nix-skills; skills = [ "nix-flakes" ]; }   # subset
      { source = skill-creator; prefix = "anthropic"; }     # namespaced
      { source = superpowers;   prefix = "superpowers"; }
    ];
  };
in {
  packages.${system} = agg.packages.${system};
  apps.${system}     = agg.apps.${system};
  devShells.${system}.default = pkgs.mkShell {
    # Declarative: converge .agents/skills/ to exactly the union —
    # install missing, update changed, sweep skills a source dropped
    # or renamed.
    shellHook = agg.reconcileScript system;
  };
}
```

It returns:

| Field            | Shape                  | Meaning |
|------------------|------------------------|---------|
| `packages`       | `forAllSystems` attrset | base per-skill keys + base `default`/`<name>` aggregates + every source's `packagePrefix`-keys, merged. Sources contribute **only** skill keys — their own `default`/aggregate keys are filtered out, so they can't clobber the base aggregate. Two sources contributing the same key (different skills) is a hard error; disambiguate with a per-source `prefix`. |
| `apps`           | `forAllSystems` attrset | the combined `install`/`uninstall`/`preview`/`reap`/`purge`/`reconcile` apps over the **union** (base + every source), all under `<verb>-${name}`. `reconcile` converges the target to the whole union; `purge` tears the whole lineage's slice out of a scope (see [Retiring agent-skill-flake](#retiring-agent-skill-flake)). |
| `reconcileScript`| `system → string`       | the declarative dev-shell one-liner: `reconcile-${name} --scope=project`. A single command (one owner of the target). |

`sources` entries are `{ source; skills ? null; pack ? null; prefix ? null; }`:
`skills = null` installs everything (a list cherry-picks by upstream name);
`pack` names a skills env (a `mkSkillsEnv` bundle) in the source's
`packages.<system>` and cherry-picks exactly its members — so a named
bundle's own membership is the source of truth, instead of restating its
skill list (mutually exclusive with `skills`).
`prefix = null` merges the source's packages verbatim, otherwise every
skill is re-prefixed via `withNamePrefixSource`. `packagePrefix` is
flake-wide (one value for filtering every source's keys and for re-keying
the merged output). `source` / `namespaceFn` apply to the optional local
`skillsDir` base, exactly as in `mkAllSkillsFlake`.

Two skills that resolve to the same install name (after any per-source
`prefix`) are a hard error — they would clobber each other under
`~/.claude/skills/<name>`. Give one a distinct `prefix`.

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
`reconcile` can't fix this either: every source shares one `agent-skill-flake`
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
installer) can share one skills directory, each declaratively owning its
own slice without sweeping the others'.

**The personal scope.** The reconcile leaves out a declared skill whose copy
in the personal skills directory is the same version, and installs one
whose copy there is a different version, with a warning (see
[A skill the personal scope already holds](#a-skill-the-personal-scope-already-holds)).
`reconcileScript system` is a plain command, so a dev shell adds
`--strict` (fail on a different version) or `--ignore-personal-scope`
(don't compare) by appending it:
`shellHook = "${agg.reconcileScript system} --strict";`.

### `mkCombination`

A **combination** is a curated, cross-cutting union of skills that is, by
construction, *both* directly consumable *and* re-composable as a source.
It is a thin wrapper over [`mkAggregateSkillsFlake`](#mkaggregateskillsflake):
the aggregate's `packages` / `apps` / `reconcileScript` pass through
verbatim, plus one home-manager `mkSkillsEnv` `env` per system over the
aggregate's skills.

```nix
let
  authoring = agent-skill-flake.lib.mkCombination {
    inherit nixpkgs;
    name    = "skillspkgs-authoring";   # reconcile ownership appName
    envName = "agent-skills-authoring"; # home-manager env package name
    sources = [
      { source = git-skills; }
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

### `mkDevshellSkillsFlake`

Builds the *whole* `outputs` of a per-repo [`skills-devshell/`
sub-flake](#project-scope-dev-shell-skills-the-skills-devshell-sub-flake) in
one call: a [`mkCombination`](#mkcombination) over the listed `sources`,
surfaced as `apps` (`reconcile` / `install` / `uninstall` / `preview` /
`reap` / `purge`, each binary suffixed `-<name>`), `packages` (so the sub-
flake is itself a valid `{ source = …; }` for further composition), and
`combinations.default`. A sub-flake's `outputs` is just a call to this:

```nix
# skills-devshell/flake.nix
outputs = { nixpkgs, agent-skill-flake, ... }@inputs:
  agent-skill-flake.lib.mkDevshellSkillsFlake {
    inherit nixpkgs;
    systems = import inputs.systems;
    name    = "myrepo-devshell";     # reconcile-ownership appName (the single owner)
    sources = [ { source = inputs.skillspkgs-combinations.combinations.authoring-with-git; } ];
  };
```

Args mirror [`mkCombination`](#mkcombination) (`sources`, `name`, `envName`,
`packagePrefix`, `agent`, `systems`), but two defaults are tuned for the
per-repo dev-shell convention so a sub-flake can omit them:

- `envName` defaults to `"agent-skills-${name}"` (not the bare `name` that
  `mkCombination` uses). A dev-shell `name` is already repo-namespaced
  (`<repo>-devshell`), so the home-manager env lands under the shared
  `agent-skills-` namespace — `agent-skills-<repo>-devshell` — matching the
  prefix `mkAllSkillsFlake` uses for its `agent-skills-<owner>-all` key.
- `packagePrefix` defaults to `"agent-skill-"` (the library default).

So the conventional sub-flake passes only `nixpkgs`, `systems`, `name`, and
`sources` — drop `envName`/`packagePrefix` unless you need non-conventional
values.

`preferences` gives the project's answers to the skills that read a
preferences file, a `{ <skill> = <text or path>; }` map:

```nix
preferences.github-workflow-pull-request-watcher = ''
  - Delete local branch: yes
  - Delete remote branch: yes
  - Update default branch: yes
'';
```

`reconcile` links each as `<skill>.preferences.md` beside the skills, from
the store and GC-rooted like a skill, records it in the lock, and lists it
in the project's exclude block. A preferences entry dropped from the flake
is swept like a dropped skill, and `purge` removes it. A key naming no skill
in the union fails evaluation. A regular file already at that path is the
project's own: `reconcile` warns and leaves it in place, and keeps it when
the entry is dropped, even where the file took the place of the flake's own
link (as checking out a commit that tracks the file does). The flake only
ever replaces or removes symlinks, so a file or directory of the project's
at a skill's path is left alone too. The single `name` owner means one `purge` (or `reap`) removes the
whole set. See [`skills-devshell/flake.nix`](skills-devshell/flake.nix) for
the live example.

`projectUpdateCommand` (default `"update-skills-devshell"`, the hook's
command) is what `reconcile` names for updating these skills when one
differs from the personal scope's copy (see
[A skill the personal scope already holds](#a-skill-the-personal-scope-already-holds)).
`mkAggregateSkillsFlake` and `mkCombination` take it too, defaulting to
`null`, which names `nix flake update --flake <project-root>`.

### `devshellSkillsHook`

Root-side wiring for a `skills-devshell/` sub-flake invoked at runtime.
Returns `{ startup; commands; standardCommands; }` so the
`nix run "$PRJ_ROOT/<dir>#<app>"` strings and the repo-agnostic command
definitions live in one place instead of being hand-rolled (and drifting)
per repo:

- `startup` — splice into `devshell.startup.<name>.text` (a plain `mkShell`
  uses `shellHook`); reconciles the skill set on `nix develop`.
- `commands` — `++` onto the devshell `commands` list; adds `reap-skills`
  (remove the whole set), `reconcile-skills` (do what entering the dev shell
  does: install, update and sweep the skill set) and `update-skills-devshell`
  (bump the sub-flake lock, then reconcile). These find the project root
  each time they run, with `git rev-parse --show-toplevel` (falling back to
  `$PRJ_ROOT` outside git), so they act on the checkout they run in rather
  than the one the dev shell was entered from. `reap-skills` and
  `reconcile-skills` pass their arguments through to the app, so
  `reap-skills --yes` (or `-y`) skips the confirmation prompt; without it and
  without a TTY, `reap-skills` refuses rather than delete, so agents and
  scripts must pass `--yes` (or `--dry-run` to only list). Arguments to
  `update-skills-devshell` go to `nix flake update` (e.g. input names).
- `standardCommands` — the repo-agnostic ci/dev/maintenance command trio
  every consumer otherwise re-hand-rolls inline: `ci`/`check`
  (`nix flake check`), `dev`/`fmt` (`nix fmt`), and
  `maintenance`/`update-flake` (`nix flake update`). They carry zero
  repo-specific data, so concatenating
  `devshellSkills.standardCommands ++ devshellSkills.commands` onto the
  menu replaces re-defining all three per repo.

Params (all optional): `dir` (`"skills-devshell"`), `scope` (`"project"`),
`reconcileApp` (`"reconcile"`), `removeApp` (`"purge"`), `reconcileArgs`
(`[ ]`: arguments added to every reconcile run, on `nix develop` and by
`reconcile-skills` and `update-skills-devshell`, such as `[ "--strict" ]`
or `[ "--ignore-personal-scope" ]`; see
[A skill the personal scope already holds](#a-skill-the-personal-scope-already-holds).
The `<dir>` sub-flake has its own lock, so it must lock an
agent-skill-flake whose reconcile has these flags: an older one refuses
them as unexpected arguments, and every dev-shell entry fails).
Every reconcile run sets `AGENT_SKILL_FLAKE_PROJECT_UPDATE_COMMAND` to
`update-skills-devshell`, the command a warning about a skill that differs
from the personal scope's copy names for the project. Pure — no provenance
threading. Assumes numtide/devshell, which exports `$PRJ_ROOT`. Usage is
shown under [the `skills-devshell`
section](#project-scope-dev-shell-skills-the-skills-devshell-sub-flake) below.

For consumers that want the *whole* dev-shell skills convention wired in one
import — including these command lists — rather than threading the hook by
hand, see [`flakeModules.devshellSkills`](#flakemodulesdevshellskills) below.

### Project-scope dev-shell skills: the `skills-devshell` sub-flake

**Recommendation: always install a repo's dev-shell skills through a
dedicated `skills-devshell/` sub-flake — never add the skill-source flakes
(`git-skills`, a combination, …) as inputs of your main flake.** A main
flake's inputs are inherited by everything that consumes it, so a library or
skills repo would drag its dev-only skill sources into every downstream lock.
Even for a leaf application that nothing imports, keep the sub-flake the
default: it keeps the skill mesh out of your root lock and out of every
`nix build` / `nix flake check` evaluation, and decouples skill-set bumps
from your software's `nix flake update`. The one cost — a second `flake.lock`
to bump — is what `update-skills-devshell` exists to make cheap.

An agent such as Claude Code that was started inside the dev shell doesn't
need to leave it to pick up a changed skill set. From one of its shell
commands:

- `update-skills-devshell` bumps the sub-flake lock and reconciles the
  skills in one step.
- `reconcile-skills` reconciles after the sub-flake changed some other way,
  such as an edited `sources` list or a pulled commit.

Whether the running agent then sees the new skills without a restart
depends on the agent.

#### Scaffolding it: `nix run …#init`

Run the scaffolder from your repo's root to write the boilerplate that
*can't* live in this library:

```bash
nix run github:nhooey/agent-skill-flake#init
```

Why a scaffolder rather than more library? A flake's `inputs` must be static
literals the evaluator reads *before* `outputs` runs, so the per-consumer
`skills-devshell/flake.nix` (its inputs plus the `mkDevshellSkillsFlake`
call) cannot be factored into a lib the way the root-side wiring is. `init`
writes exactly that, idempotently and without clobbering:

- `skills-devshell/flake.nix` — a sub-flake calling
  [`mkDevshellSkillsFlake`](#mkdevshellskillsflake) with its `name` derived
  from your `git remote get-url origin` (falling back to the directory
  basename) and `agent-skill-flake.url` pointed at this lineage. The sub-flake's
  reconcile-owner `name` gets a `-devshell` suffix (`<repo>-devshell`) while the
  root `devshellSkills` `name` in the printed snippet is the bare `<repo>`, so
  the two differing names are expected. You fill in its `sources` and run
  `nix flake lock ./skills-devshell`.

`init` does not touch `.gitignore`: the installed skills are ignored, one
line each, through `.git/info/exclude`, which every verb that changes the
project-scope skills rewrites
(see [Install scope](#install-scope)).

It then **prints** the root `flake.nix` wiring snippet for you to paste (it
never edits your root flake — too varied to touch safely). Flags: `--force`
overwrites the scaffolded `skills-devshell/flake.nix`, `--dry-run` prints what it would write
without touching disk, `-h`/`--help` shows usage.

How the isolation works:

- The **`skills-devshell/` sub-flake** declares the skill sources as *its
  own* inputs and calls [`mkDevshellSkillsFlake`](#mkdevshellskillsflake),
  which surfaces the whole set as runnable apps (`reconcile`, `install`,
  `purge`, …) under one reconcile owner. The sub-flake has its **own
  `flake.lock`**, so the skill sources live only there.
- The **root flake invokes those apps at runtime by path** —
  `nix run "$PRJ_ROOT/skills-devshell#reconcile"` — rather than taking
  the sub-flake as an input. The root therefore keeps **zero skill inputs**;
  the skill closure is realized only when the dev shell actually installs.

The root-side wiring is two splices, both produced by
[`devshellSkillsHook`](#devshellskillshook) so the `nix run` strings and the
repo-agnostic `skills`-category commands live in one place:

```nix
# main flake.nix — needs only agent-skill-flake as an input (a zero-skill-input
# leaf lib), NOT the sub-flake or any skill source.
let devshellSkills = agent-skill-flake.lib.devshellSkillsHook { };
in {
  # numtide/devshell shown; a plain mkShell uses shellHook for the startup line.
  devshell.startup.install-skills.text = devshellSkills.startup;          # reconcile on `nix develop`
  commands = [ /* your repo's own ci/dev/… commands */ ]
    ++ devshellSkills.commands;                                           # reap-skills + reconcile-skills + update-skills-devshell
}
```

**Don't duplicate the sub-flake in your repo from scratch — copy and adapt
this repo's canonical pair:**

- [`skills-devshell/flake.nix`](skills-devshell/flake.nix) — the sub-flake.
  Adapt its `sources` to the skill set you want, and point its
  `agent-skill-flake.url` at `github:nhooey/agent-skill-flake` (this repo
  uses `path:..` only because it dogfoods its own in-progress lib).
- [`flake.nix`](flake.nix) — the root-side `devshellSkillsHook` wiring shown
  above, in context.

This repo's own `skills-devshell/` is the live example: it sources skillspkgs'
`authoring-with-git` combination (the git/GitHub pack plus the authoring
tooling) as the dev shell's entire skill set.

### `flakeModules.devshellSkills`

The [`devshellSkillsHook`](#devshellskillshook) wiring above is two manual
splices into a `devshells.default` you still write yourself — the motd, the
`startup` line, and the `standardCommands ++ commands` menu. Every consumer
repeats that same `devshells.default` block. `flakeModules.devshellSkills` is
a [flake-parts](https://flake.parts) module that collapses all of it to one
import plus an options block:

```nix
# main flake.nix (flake-parts) — agent-skill-flake is the only input needed
# for the dev shell; NO `devshell` input, NO hand-rolled devshells.default.
{
  imports = [ inputs.agent-skill-flake.flakeModules.devshellSkills ];
  agent-skill-flake.devshellSkills.name = "my-repo";

  # Repo-specific packages/commands still go on devshells.default directly —
  # devshell list options merge, so these add to (don't replace) the module's
  # standard + skills commands:
  perSystem = { pkgs, ... }: {
    devshells.default.packages = [ pkgs.jq ];
    devshells.default.commands = [ /* your extra commands */ ];
  };
}
```

The module sets `devshells.default`'s `name`, `motd`, the install-skills
`startup`, and `commands` (the ci/dev/maintenance trio plus `reap-skills` /
`reconcile-skills` / `update-skills-devshell`). Beside that dev-shell wiring
it brings the [shared skill checks](#skill-checks), which do nothing in a
flake without a skills folder. `treefmt` is deliberately not bundled, since
real consumers diverge on it.

- **No `devshell` input required.** The exported module bundles
  agent-skill-flake's own `inputs.devshell.flakeModule`. **Caveat:** if you
  already import your own `inputs.devshell.flakeModule`, drop it — importing a
  second, differently-pinned devshell module loads both and merges
  `devshells.default` (redundant at best, version-skew at worst).
- **Overriding.** `name` and `motd` are set with `lib.mkDefault`, so a plain
  `perSystem.devshells.default.name = …` (or `.motd`) wins. Repo-specific
  `packages` and `commands` are list options that merge by concatenation, so
  set them directly — no extra option needed.

Options under `agent-skill-flake.devshellSkills`:

| Option | Default | Meaning |
|---|---|---|
| `name` | `"dev shell"` | devShell name + the label in the generated motd. |
| `motd` | `null` | Full motd string; `null` generates the standard banner from `name`. |
| `dir` | `"skills-devshell"` | Sub-flake dir (under `$PRJ_ROOT`) reconciled on `nix develop`. |
| `scope` | `"project"` | Install scope passed to the reconcile / removal apps. |
| `reconcileApp` | `"reconcile"` | Sub-flake app run on `nix develop` to converge the set. |
| `removeApp` | `"purge"` | Sub-flake app `reap-skills` invokes to remove the whole set; `reap-skills`' arguments (e.g. `--yes`) pass through to it. |
| `reconcileArgs` | `[ ]` | Arguments added to every run of `reconcileApp`, such as `[ "--strict" ]` or `[ "--ignore-personal-scope" ]` (see [A skill the personal scope already holds](#a-skill-the-personal-scope-already-holds)). The `<dir>` sub-flake must lock an agent-skill-flake whose reconcile has these flags, or every dev-shell entry fails. |
| `includeStandardCommands` | `true` | Prepend the ci/dev/maintenance trio; the three `skills` commands are always included. |

`flakeModules.default` is an alias for `flakeModules.devshellSkills`. This repo
dogfoods the module in its own [`flake.nix`](flake.nix) (listing the bundle's
pieces directly rather than `self.flakeModules.devshellSkills`, which would be
an eval cycle).

## Skill checks

Every flake that imports [`flakeModules.devshellSkills`](#flakemodulesdevshellskills)
gets two checks on its own skills folder, so `nix flake check` runs them with
nothing to name:

- `checks.<system>.skill-layout`: an installed skill holds only what it runs,
  and its Python scripts import only the standard library and the `.py`
  modules beside them.
- `checks.<system>.skill-description`: every SKILL.md opens with frontmatter
  that names the skill and describes it.

Each prints one line per problem, `<skill>: <problem> (<rule>)`, and fails
when there is any. A flake that wires its own dev shell imports
`flakeModules.skillChecks`, the checks alone. A flake without a skills folder
gets neither check; one whose skills folder holds no skill folder (only a
`.gitkeep`, say) gets both, and both fail.

Every tool a check runs starts in an empty folder and reads the skill's
files by absolute path, so no folder name or settings file a skill ships,
such as a `pyproject.toml`, `ruff.toml`, `lychee.toml` or `.lycheeignore`,
changes what it finds. pylint reads a copy of each `scripts/` folder that
holds only its folders and `.py` files, since it puts a script's folder
first on Python's path and would load a compiled module there, such as a
`sqlite3.so`, in place of the standard library's. The layout check follows
links in `scripts/` as Python's import does, so a module linked in from
elsewhere is checked and a link that names nothing is left out. Anything
there that `find -L` can't walk, such as a link that loops back to its own
folder or one above it, stops the check with status 2, the status of a tool
that failed, and a `walkable-scripts` line holding find's own words for it.

### Rules

| Check | Rule | Fails when |
|---|---|---|
| both | `skills-exist` | The skills folder holds no skill folder: a folder, not a link, whose name doesn't start with a dot and isn't `__pycache__`. |
| `skill-layout` | `dot-folders` | A folder directly in the skills folder has a name starting with a dot, such as `skills/.x/`. The checks pass over it, while agent-skill-flake builds it as a skill when it holds a SKILL.md and looks for skills in it otherwise. A file, such as `.gitkeep`, and a link pass. |
| `skill-layout` | `test-folders` | A folder named in `test-folders`, or a link of that name, whatever it points at, sits anywhere under the skills folder. Tests go in `tests/<skill>/`. |
| `skill-layout` | `test-files` | A file matching a pattern in `test-files`, or a link of such a name, whatever it points at, sits anywhere under the skills folder. |
| `skill-layout` | `standard-library-imports` | A skill's Python script, `scripts/**/*.py`, imports a module that is neither in the standard library of the Python the check is built with nor a `.py` file in the script's own folder, or holds a comment with `pylint:` in it, such as `# pylint: disable=import-error` or `# pylint: skip-file`, which could hide one. A folder beside the script, a package or a namespace package, linked or not, fails, under `standard-library-names` when it has the name of a module in the checking Python's standard library; one named after a removed module is not enforced (see below). Text in a string is no comment. |
| `skill-layout` | `standard-library-names` | A `.py` module anywhere in a skill's `scripts/`, or a folder beside a script (in a folder that holds a `.py` file), linked or not, has a name in the checking Python's `sys.stdlib_module_names`, such as `scripts/json/` or `scripts/secrets.py`. Python would import it in place of the standard library's, or the standard library's in place of it, and FawltyDeps reports no import of a standard-library name. |
| `skill-layout` | `compiled-modules` | A compiled module, a file or link named `*.so`, `*.pyd` or `*.pyc`, sits anywhere in a skill's `scripts/`, where Python would import it in place of a standard-library module of its name. |
| `skill-layout` | `walkable-scripts` | `find -L` reports something in a skill's `scripts/` it can't walk, such as a link loop, `scripts/loop -> .`, or a folder it can't read. The check stops with status 2. |
| `skill-layout` | `python-syntax` | Python can't parse a skill's script. |
| `skill-layout` | `relative-imports` | A skill's script imports relative to a package (`from . import x`); a script imports a module beside it by its name. A `# noqa` comment doesn't silence it. |
| `skill-layout` | `unique-script-modules` | Two Python scripts in different folders share a module name. A package's `__init__.py` has its folder's name. |
| `skill-layout` | `tests-name-skills` | A folder directly under `tests/` is named after no skill. |
| `skill-description` | `folder-name` | A skill's folder name isn't lowercase letters and digits in words joined by hyphens, at most 64 characters. |
| `skill-description` | `skill-md` | A skill folder holds no SKILL.md. |
| `skill-description` | `frontmatter` | SKILL.md doesn't open with a block between `---` lines, or the block isn't a YAML mapping, read with `yq --front-matter=extract`. Line endings may be LF or CRLF. |
| `skill-description` | `name` | The frontmatter's `name` isn't the folder name. |
| `skill-description` | `description` | `description` is missing, not a string, blank, or over 1,024 characters. |
| `skill-description` | `trigger-first` | A skill in `trigger-first` has a description that doesn't open on `trigger-first-prefix` or runs over 500 characters, or a name in `trigger-first` is no skill's folder. |
| `skill-description` | `skill-flake` | With `skill-flake` on, a skill has no `flake.nix`, or its `outputs` doesn't call `mkSkillFlake` with the folder name as `skillName` (see the form below). |
| `skill-description` | `relative-links` | A relative link in SKILL.md, outside code blocks and code spans, names no file inside the skill's folder. lychee checks it offline, on a copy of the skill alone, so a link out of the skill fails too. |

### The tools behind the import rules

The import rules use three linters, each for what it can see, and Python's
tokenize:

| Tool | Reports | Rule |
|---|---|---|
| [FawltyDeps](https://github.com/tweag/FawltyDeps) `--check-undeclared`, with no dependency declared and an empty folder as `--base-dir`, so nothing is first-party; the folder's name holds a dash, since FawltyDeps takes that name itself as first-party | Each import that isn't a standard-library name, the libraries pylint runs on and the folders beside the script among them; jq then drops those of a `.py` file beside the script, from the list `find -L` makes | `standard-library-imports` |
| [pylint](https://pylint.readthedocs.io) `import-error`, settings in [`lib/config/skill-checks-pylintrc`](lib/config/skill-checks-pylintrc), run on one skill at a time, since it puts the folder of every script it reads on Python's path | Each import the Python running the check can't resolve with the script's folder on its path, such as a module removed from the standard library (`imp`, `distutils`, `cgi`) | `standard-library-imports` |
| `python3 -m tokenize`, which decodes a script by its coding line and tells comments from strings | Each comment token holding `pylint:`, which could switch `import-error` off for a line, a block or the whole file, in whatever coding the script declares, such as UTF-7 | `standard-library-imports` |
| `python3 -c` printing `sys.stdlib_module_names`, matched against the folders and `.py` files `find -L` lists | Each `.py` module in `scripts/`, or folder beside a script, named after a module of the checking Python's standard library | `standard-library-names` |
| pylint `syntax-error` | A script that doesn't parse | `python-syntax` |
| [ruff](https://docs.astral.sh/ruff) `TID252` with `ban-relative-imports = "all"`, settings in [`lib/config/skill-checks-ruff.toml`](lib/config/skill-checks-ruff.toml) | Every relative import | `relative-imports` |

FawltyDeps knows the standard-library names of every Python version, so
pylint, which imports through the checking Python itself, catches the removed
ones; pylint can import its own dependencies, so FawltyDeps catches those.
Not enforced:

- On a case-insensitive file system, such as macOS's default, a module name
  that differs from a standard-library one only in case, such as
  `ConfigParser`, passes.
- A module the checking Python has but an older Python lacks, such as
  `tomllib` before 3.11, passes.
- A package in a skill's `scripts/` named after a module removed from the
  standard library, such as `imp` or `distutils`, passes when a script
  imports it: FawltyDeps counts the name as the standard library's, and
  pylint resolves the vendored folder.

A standard-library module that the checking platform lacks, such as `winreg`
on macOS or Linux, fails.

### The `skill-flake` form

The `skill-flake` rule reads a skill's `skillName` by calling its flake's
`outputs` with a stand-in `mkSkillFlake` that returns its arguments, and empty
sets for every other input, so the flake builds nothing. It reads this form,
where `outputs` names agent-skill-flake's input `agent-skill-flake` and reads
no other input outside the arguments it passes on:

```nix
{
  outputs =
    { nixpkgs, agent-skill-flake, ... }:
    agent-skill-flake.lib.mkSkillFlake {
      inherit nixpkgs;
      skillName = "my-skill"; # the skill's folder name
      src = ./.;
    };
}
```

An `outputs` that reads an attribute of another input, such as
`nixpkgs.lib`, or that names the input otherwise, stops the evaluation of the
whole flake with Nix's own error rather than failing the rule.

### Settings: `skill-checks.toml`

A skill repository changes the checks' settings in a `skill-checks.toml` at
its root. It names only what it changes: tables merge key by key, and a list
or other value replaces the default whole. A key that isn't a setting, or a
value of the wrong type, fails evaluation. The file is data that only the
checks read, so a repository can add it before its `flake.lock` reaches a
version of agent-skill-flake with the checks.

```toml
# skill-checks.toml
[description]
trigger-first = ["my-skill-one", "my-skill-two"]
```

| Setting | Default | Meaning |
|---|---|---|
| `skills-dir` | `"skills"` | The folder, relative to the root, holding one folder per skill. Without it, neither check is made; with no skill folder in it, both fail on `skills-exist`. |
| `layout.enable` | `true` | Make `checks.<system>.skill-layout`. |
| `layout.test-folders` | `["test", "tests", "golden", "stubs"]` | Folder names that mark tests or their data. |
| `layout.test-files` | `["test_*", "*_test", "*_test.*", "*.bats"]` | Shell patterns of test file names. |
| `layout.unique-script-modules` | `true` | Check the `unique-script-modules` rule. |
| `layout.tests-name-skills` | `false` | Check the `tests-name-skills` rule, for a repository whose `tests/` holds only folders named after skills. |
| `description.enable` | `true` | Make `checks.<system>.skill-description`. |
| `description.trigger-first` | `[]` | Skills held to the `trigger-first` rule. |
| `description.trigger-first-prefix` | `"Load "` | What a trigger-first description opens on. |
| `description.skill-flake` | `false` | Check the `skill-flake` rule, for a repository whose skills each have their own `flake.nix`. |
| `description.relative-links` | `true` | Check the `relative-links` rule. |

[`lib/config/skill-checks.toml`](lib/config/skill-checks.toml) holds the
defaults, [`lib/skill-checks.nix`](lib/skill-checks.nix) merges the file over
them and builds the checks, and the scripts in
[`lib/bash/`](lib/bash/skill-layout-check.sh) apply the rules.

To run the checks against a skill repository's checkout before its lock
moves to a version with them, point its `agent-skill-flake` input at a
checkout of this repository:

```bash
nix flake check --override-input agent-skill-flake path:/path/to/agent-skill-flake --no-write-lock-file
```

## Install scope

Every install/uninstall/reap/purge/reconcile/preview invocation **must** declare
its `--scope`. There is no implicit default — the choice is forced at the
call site so an install can never silently land in a place the caller
didn't choose. The three scopes:

```sh
# Personal: $HOME/<agent.personalSuffix>/  (e.g. $HOME/.claude/skills/)
nix run .#install -- --scope=personal

# Project:  <project-root>/<agent.projectSuffix>/  (e.g. <root>/.agents/skills/)
#           Walks up from $PWD looking for .git/ (preferred), then
#           flake.nix. Hard-errors if neither marker is found.
nix run .#install -- --scope=project

# Custom:   the literal path you name.
nix run .#install -- --scope=custom --root=/etc/agent-skills
```

At project scope, `install` and `reconcile` also keep the repo layout:

- **One shared directory.** The `claude-code` profile installs into
  `<root>/.agents/skills/`, the directory other agents read, and makes
  `<root>/.claude/skills` a relative symlink to it (`../.agents/skills`),
  creating `.claude/` if needed. Every agent sees the same skills.
- **Ignored without a commit.** Exactly what the flake manages is listed,
  one line each, in a marked block of
  `$(git rev-parse --git-common-dir)/info/exclude`: `/.claude/skills`, the
  lock file, the [local config file](#user-config-agent-skill-flake-apply-and-sync-project)
  `/.config/agent-skill-flake/config.local.toml`, and each skill the lock
  names, such as `/.agents/skills/alpha`. The block is rewritten after every
  `install`, `reconcile`, `uninstall`, `reap` and `purge`, so a removed
  skill's line never hides a folder of your own with that name, and lines
  outside it are kept. Linked worktrees share that
  file, and no tracked file in the repo changes, so this works in a repo
  you don't control.
- **Your own files stay tracked.** A skill or a
  `<skill>.preferences.md` the project adds to `.agents/skills/` is not
  ignored, so it can be committed. Preferences declared through
  [`mkDevshellSkillsFlake`'s `preferences`](#mkdevshellskillsflake) are
  links the flake manages, and are ignored like its skills. A repo that doesn't want skills
  committed can refuse them with its own hook or a repository rule.
- **An existing `.claude/skills/` directory.** If every entry in it was
  installed by agent-skill-flake (judged as `reconcile` judges ownership:
  the lock's `installedBy`, the sentinel's `managedBy`, or a matching GC
  root), its entries move to `.agents/skills/` and the directory becomes
  the symlink. If it holds anything else, the run exits non-zero, lists the
  foreign entries, and changes nothing.
- **A `.claude/skills` symlink or file.** A symlink that already resolves
  to `.agents/skills/` is rewritten as the relative link. Any other symlink,
  or a file, is renamed to `.claude/skills.pre-agent-skill-flake`, its
  target untouched, and the run goes on; if that name is taken, the run
  exits non-zero and changes nothing.

`--scope=custom` requires `--root=<path>`; `--root` is rejected with any
other scope. Missing `--scope` exits non-zero with a usage hint. Other
flags:

| Flag                  | Default                              | Meaning |
|-----------------------|--------------------------------------|---------|
| `--gcroots-dir=<path>`| `/nix/var/nix/gcroots/per-user/$USER`| Override the per-user GC-roots dir, where the shared roots and each target's records go, under `claude-skills/` (see [Default: symlink + GC root](#default-symlink--gc-root)). Primarily for the test suite — rarely useful in practice. |
| `--profile`           | (off)                                | `install` only: install via `nix profile install` instead of the default direct-symlink mode. See [`--profile`](#--profile-via-nix-profile-install). |
| `--strict`            | (off)                                | `reconcile --scope=project` only: exit 1 when a declared skill differs from the personal scope's copy. See [A skill the personal scope already holds](#a-skill-the-personal-scope-already-holds). |
| `--ignore-personal-scope` | (off)                            | `reconcile --scope=project` only: don't compare the declared skills with the personal scope's copies. |
| `-h`, `--help`        | —                                    | Print help and exit. |

Positional args after the flags are skill-name selectors (subset install):

```sh
nix run .#install -- --scope=project nix-flakes git-ssh
```

`mkAllSkillsFlake` apps install all discovered skills with no positional
args, or only the named subset when given. An unknown skill name is a
hard error listing what's available — the install-time equivalent of
eval-time typo protection.

### A skill the personal scope already holds

An agent reads the personal skills directory as well as the project's, and
Claude Code uses the personal copy when both hold a skill of the same
name. So `reconcile --scope=project` compares each declared skill with the
personal directory's copy of that name:

- **The same version:** the project's copy isn't installed. A link an
  earlier reconcile made is removed with its GC root, its `skills` entry
  in the lock and its exclude line, and the lock lists the skill under
  `satisfiedByPersonalScope` (see [Lock file](#lock-file)). The run prints
  `N declared skill(s) left to the same version in <personal-dir>.`
- **A different version:** the project's copy is installed as well, and
  the run prints one line per skill on stderr, naming both versions, the
  copy the agent uses, and how to bring each side up to date:

  ```text
  WARNING: beta is sha256:3f0c2a91d4b7 in the personal scope (/home/me/.claude/skills/beta) and sha256:8e51b0c6a2f9 in this project; both are installed. Claude Code uses the personal copy. To update both to the latest: for the personal copy, run `my-home-update`; for the project's, run `update-skills-devshell`.
  ```

  With `--strict` the line starts `ERROR:`, and the reconcile exits 1 once
  it has converged.
- **No copy of that name, or no personal directory** (as in CI or a
  sandbox): the skill installs as at any other scope. So does a personal
  entry whose links pass through the project's own skills directory, which
  is the project's copy under another name, and a personal copy that can't
  be read, which the run reports in one `WARNING:` line.

Every reconcile compares afresh, from the files, and never trusts what an
earlier run recorded: once the personal copy is removed or changes, the
next reconcile installs the project's.

Two copies are the same version when their content hashes match. When
both copies are in the Nix store and their sentinels record a
`contentHash` of the same scheme (see [Build behavior](#build-behavior)),
those are compared, and the store path, the sentinel's `version` and
`managedByRev` take no part. Otherwise, as for a copy built by an
agent-skill-flake that didn't record the hash, or one outside the store,
both folders are hashed as they stand, computed the same way. That
fallback sees the store paths the build wrote into the scripts (patched
shebangs, `scriptInputs`' PATH lines and wrappers), so the same source
built against two different nixpkgs compares as a different version: the
project's copy is installed too, with the warning.

The personal directory is the one the agent reads,
`$HOME/<agent.personalSuffix>` (`~/.claude/skills` for Claude Code),
followed through any symlinks, as when Home Manager links it to another
directory. A project whose skills directory is that same directory skips
the comparison. These environment variables change what the reconcile
looks at and says:

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_SKILL_FLAKE_PERSONAL_DIR` | `$HOME/<agent.personalSuffix>` | The personal skills directory to compare with. |
| `AGENT_SKILL_FLAKE_PERSONAL_UPDATE_COMMAND` | (unset) | The command that updates the personal skills, quoted in the warning. Unset, the warning says to update the flake that installs the personal directory and rebuild it. |
| `AGENT_SKILL_FLAKE_PROJECT_UPDATE_COMMAND` | the builder's `projectUpdateCommand`, else `nix flake update --flake <project-root>` | The command that updates the project's skills. [`mkDevshellSkillsFlake`](#mkdevshellskillsflake) builds in `update-skills-devshell`, and [`devshellSkillsHook`](#devshellskillshook) also sets the variable to it. |

The personal update command belongs to the user's machine, so set it where
the user's environment is set, such as Home Manager's
`home.sessionVariables`. A dev shell passes `--strict` or
`--ignore-personal-scope` by appending it to `reconcileScript`'s command
(`"${agg.reconcileScript system} --strict"`), through
[`devshellSkillsHook`](#devshellskillshook)'s `reconcileArgs`, or through
the [flake module's](#flakemodulesdevshellskills) `reconcileArgs` option.
The two flags together are a usage error, and so is either one at
personal or custom scope, as `--root` is outside custom scope. Personal and
custom scope reconciles, and `install`, don't compare. `agent-skill-flake
sync-project` does compare, with the defaults and the variables above, and
rejects both flags as unexpected arguments.

### Default: symlink + GC root

The Nix-native install. Three things happen:

1. **User-facing symlink.**
   `<target>/<skillName>` is created as a symlink to
   `<store-path>/share/claude-skills/<skillName>`. Claude Code (or
   whichever agent profile you picked) follows it transparently.
2. **A shared per-user GC root, and a record per target.**
   Identical builds share one GC root, keyed by store path, and each
   target records which builds it uses. Under
   `/nix/var/nix/gcroots/per-user/$USER/claude-skills/`:

   | Path | What it is |
   |------|------------|
   | `store/<store-path-name>` | The GC root: a link to the store path, protecting it from `nix-store --gc`. |
   | `store/<store-path-name>.refs` | The root's anchor: a regular file holding the store path. |
   | `targets/<target-hash>/<skillName>` | The target's record: a hard link of the anchor of the build it links. |
   | `targets/<target-hash>/<skillName>.previous` | The record of the build before it. |
   | `targets/<target-hash>/.target` | A link to the target's resolved dir. |
   | `lock` | The lock every change below `claude-skills/` takes. |

   `<target-hash>` is the first 12 hex characters of the SHA-256 of
   `<target>`'s absolute path with symlinks resolved (so on macOS
   `/tmp/x` and `/private/tmp/x` share their records). Each target —
   the user scope, each project's skills dir, each custom root — holds
   its own records, and an anchor's link count is one more than the
   records using its root, so a root goes only when the last record
   using it goes: installing or uninstalling a skill in one target never
   unroots another target's link. Nix takes only the `store/` links for
   roots, so a machine with hundreds of worktrees, each installing the
   same skills, keeps one root per build rather than one per worktree
   and skill. Override the gcroots dir with `--gcroots-dir=<path>`
   (test-suite use; rarely useful in practice).

   A target records its current and previous builds of each skill, and
   no older ones. When an install or reconcile replaces a skill's store
   path, the replaced path's record moves to `<skillName>.previous`,
   displacing the build before it. Uninstall removes both records.
   `reap` and `purge` remove their own target's previous-build records
   whose current record is gone; `prune-gc-roots` removes every
   target's.

   Target dirs come and go, such as a git worktree's `.agents/skills`,
   and a removed target's records still point at live store paths, so
   nothing else marks them as orphans. `reap` and `purge`, in any target,
   remove every record of a target whose `.target` points at a dir that
   is gone, then every root no record uses any more. Usually they read
   only each target's `.target`, their own target's records and the
   shared roots, so they stay fast with hundreds of targets; they read
   every target's records only to drop the records of a store path that
   is gone, which its root rarely lets happen, and while a legacy
   `claude-skill-<skillName>` root is left.

   Every change below `claude-skills/`, and every check an install makes
   before deciding it has nothing to change, holds an exclusive
   `flock(1)` on its `lock`, taken once per run and released before the
   run starts `git`. Runs of this revision therefore serialize: none
   removes a root between another's counting of its records and its
   adding one, nor removes a target's records while an install into the
   same path is checking them. `prune-gc-roots --delete` takes the lock
   after its search and reads each entry again under it. A run that
   can't get the lock within 120 seconds
   (`AGENT_SKILL_FLAKE_GC_LOCK_TIMEOUT`) warns once and changes nothing
   below `claude-skills/`, which leaves:

   - after `install`, the records it would have written missing until
     the next install or reconcile;
   - after `reconcile`, the same, and the records of the skills it
     swept kept, with their roots, until `prune-gc-roots` finds those
     skills no longer linked;
   - after `uninstall` or `purge`, the links and their lock entries gone
     but the target's records kept, with their roots, until
     `prune-gc-roots` finds the skills no longer linked, and `purge`'s
     sweep of the shared layout left for the next `reap` or `purge`;
   - after `reap`, the shared layout unswept until the next `reap` or
     `purge`.

   The counts live in hard links, so a copy of the gcroots dir must keep
   them: use `rsync -aH` (macOS's own `rsync` takes `-H` too) or GNU
   `cp -a`. macOS's `/bin/cp -a` copies hard-linked files as separate
   files, as do `cp -r` and `rsync` without `-H`. A copy that splits a
   record from its anchor makes the anchor look unused to every run but
   that target's own `install`, `reconcile`, `reap` or `purge`: any
   other run that drops a record of the same build, such as a `reap`,
   `purge`, `prune-gc-roots` or `uninstall`, or an `install` or
   `reconcile` that sweeps a skill or replaces a build, can remove a
   root a split record still needs. `install`, `reconcile`, `reap` and
   `purge` relink their own target's split records, current and
   previous-build, before they count, but that repairs one target at a
   time. Don't use a copy that split them:
   copy the gcroots dir again from the original, keeping the hard
   links.

   An agent-skill-flake rev from before the shared layout, which a dev
   shell's `skills-devshell/flake.lock` may still pin, writes flat roots
   straight in the gcroots dir instead:
   `claude-skill-<target-hash>-<skillName>` and its `.previous`, beside
   the record `claude-skill-<target-hash>.target`. They keep protecting
   their store paths until pruned. `install` and `reconcile` move their
   target's flat roots into records, each record written before its flat
   root goes, and `reap`, `purge`, `uninstall` and `check` handle the flat
   roots they find as before. The flat record goes once none of its
   target's flat roots is left.

   Such an older rev, run in a target this one has moved into records,
   doesn't see the records: its `check` reports every link as
   `unrooted` or `wrongly rooted`, its `install` and `reconcile` write
   flat roots again, and the next run of this rev moves them back into
   records, so the two alternate without leaving a link unrooted. Its
   `uninstall` removes only flat roots, leaving the record, and so the
   root, until `prune-gc-roots` finds the skill no longer linked.

   Records and flat roots with no record of their dir can't be traced to
   it this way, such as those an older agent-skill-flake writes from a
   dev shell that pins a rev without such records. `prune-gc-roots` finds
   the targets that still exist, by their lock files under `$HOME` and
   each `--search=<dir>`, by their records and at the personal scope, and
   lists every record and flat root whose target it didn't find or no
   longer links the skill, every previous-build one whose current one is
   gone, and the shared roots their removal leaves without a record. It
   names each dir its search couldn't read, since a target inside one
   looks gone. It removes them only with `--delete`, refuses `--delete`
   when it finds no lock file at all, and keeps legacy shared roots and
   anything changed in the last hour. It removes nothing but those links
   and records: no store path, and no garbage collection.

   ```sh
   nix run --refresh github:nhooey/agent-skill-flake#prune-gc-roots              # list, with counts
   nix run --refresh github:nhooey/agent-skill-flake#prune-gc-roots -- --delete  # remove them
   ```

   `--refresh` skips Nix's cached copy of the branch: a `prune-gc-roots`
   older than previous-build roots takes each one for a root of a skill
   named `<skillName>.previous`, which no target links, and lists it.

   A shared root with no target hash, `claude-skill-<skillName>`, is
   left by older installs. Ownership checks still accept it, and
   install, reconcile and uninstall leave it alone, since it may be the
   only root protecting some other target's link. `reap` and `purge`
   remove it once its store path is gone, or once a target's current
   record or flat root points at the same store path; re-running
   `install` or `reconcile` in each target gives every target its own
   record, after which a `reap` clears the legacy roots.

   `check` reports each skill and preferences link in the target's lock
   whose store path has no root of the target's own, its record of the
   store path's shared root or its flat root, as `unrooted` or, when only
   a legacy root or another target's record protects it, `wrongly
   rooted`, and exits 1; it prints nothing and exits 0 when every link
   is rooted. It reads the gcroots dir once, so it stays fast with
   thousands of roots, where `nix-store --query --roots` per link scans
   every process's open files.
3. **Aggregate lock entry.**
   An entry is upserted into `<target>/.agent-skill-flake-lock.json`
   summarizing what was installed (provenance from the per-skill
   sentinel + the resolved `storePath` + an `installedAt` timestamp).
   See [Lock file](#lock-file) below.

The user-facing symlink is read-only by virtue of pointing into the
store. To **upgrade** a skill, re-run `nix run .#install`: the symlink
is replaced atomically, the target's record points at the new store
path's root, the old path keeps the previous-build record, the one
before it becomes GC-eligible once no other target records it, and the
lock entry is refreshed.

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

## User config: `agent-skill-flake apply` and `sync-project`

The `agent-skill-flake` command reads one agent-neutral config file and
does two things with it: `apply` writes user-level settings (each agent's
trusted folders, and a git hook), and `sync-project` installs the skills
you configured for a repository into that repository's project scope. It
needs no Home Manager and no change to the repository.

```sh
nix run github:nhooey/agent-skill-flake#agent-skill-flake -- apply
nix profile install github:nhooey/agent-skill-flake#agent-skill-flake   # puts it on PATH for the hook
```

### The files

| File | Holds |
|------|-------|
| [`lib/config/defaults.toml`](lib/config/defaults.toml), shipped in the package | Every setting with its default and a comment. `agent-skill-flake config show --defaults` prints it. |
| `${XDG_CONFIG_HOME:-$HOME/.config}/agent-skill-flake/config.toml` | User-global: `[defaults]`, one `[repo."<host>/<owner>/<name>"]` table per repository, and `[agents.<agent>]` tables, naming only what you change. |
| `<repo-root>/.config/agent-skill-flake/config.local.toml` | An override for one checkout, with the shape of one repo table. Never committed. |

```toml
# ~/.config/agent-skill-flake/config.toml

[agents.claude-code]
trusted-dirs = ["~/git", "/srv/shared"]       # → permissions.additionalDirectories

[defaults]                                     # under each configured repo's settings
skills = ["github:nhooey/git-skills#agent-skills-nhooey-git-all"]

[repo."github.com/acme/widget"]
skills = [
  "github:nhooey/git-skills#agent-skills-nhooey-git-all",
  "github:acme/team-skills#agent-skill-acme-review",
]
```

```toml
# <repo-root>/.config/agent-skill-flake/config.local.toml

skills = ["path:./my-skills#agent-skills-me-all"]
merge = { override = ["skills"] }              # optional: see "Merging" below
```

The TOML is read through Nix (`builtins.fromTOML`, via `nix-instantiate`),
so nothing but Nix is needed to parse it.

**Shipped defaults.** Your files are merged over the shipped defaults file,
so a setting you leave out keeps its default, and with no config file at
all the command runs on the defaults alone. A key the shipped file doesn't
have, such as a misspelt setting or an agent with no writer, is an error
naming the file and the key, and nothing is changed.
`agent-skill-flake config show` prints your user-global file merged over
the defaults, as JSON.

**Repo keys.** A repo table's key is the normalized `origin` URL:
`git@github.com:acme/widget.git`, `https://github.com/acme/widget(.git)` and
`ssh://git@github.com[:port]/acme/widget` are all `github.com/acme/widget`.
The user, the port and a trailing `.git` or `/` are dropped, and the host is
lowercased; the path keeps its case. Write keys in that form.

**`skills` entries** are flake installables, built with `nix build` from
the repo root (so `path:./…` is relative to the repo). Each must build to a
package with skills under `share/claude-skills/<name>/`, which every
builder in this library produces: a single skill (`agent-skill-<owner>-<name>`),
an aggregate (`agent-skills-<owner>-all`), or a `mkSkillsEnv` bundle. A
`/nix/store/…` path to such a package is used as it is, without a build.
Two entries that provide the same skill name are an error.

### Precedence and merging

Highest first: **the local file > the user-global repo entry >
`[defaults]` > the shipped `[defaults]`**.

- **By default the local file replaces the user-global entry** for that
  repo entirely. Only `[defaults]` still sits underneath it.
- **With a top-level `merge` table**, the local file is instead
  deep-merged over the user-global entry: tables merge key by key,
  recursively, and any other value (string, number, boolean, array) from
  the local file wins. `merge` itself never reaches the result.
- **`merge.override`** lists dotted paths, such as `"skills"`, whose
  whole subtree, descendants included, is taken from
  the local file instead of being merged. A listed path the local file
  doesn't set keeps the merged value. Keys that contain a dot can't be
  named in a path.
- `[defaults]` is deep-merged under the repo entry, or under the local file
  when it replaces the entry. A repo with neither an entry nor a local file
  is left alone, whatever `[defaults]` says.

Arrays are replaced, never concatenated, so `skills` always comes whole
from one layer, and `sync-project` names that layer for each skill.

### `agent-skill-flake apply`

Reads the user-global file, merged over the shipped defaults, and writes:

- **Each agent's settings.** For `[agents.claude-code]`, `trusted-dirs` is
  added to `permissions.additionalDirectories` in
  `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json`; a leading `~` is
  expanded. Directories already listed stay, the configured ones are added
  once each, and every other key is kept. Only `claude-code` has a writer
  so far, so it is the only agent the shipped defaults list; another
  agent's table is an unknown key. Writers live in
  [`lib/bash/apply.bash`](lib/bash/apply.bash), one function per agent.
- **The git hook.** In your global git config:

  ```ini
  [hook "agent-skill-flake-sync"]
    event = post-checkout
    command = agent-skill-flake sync-project --from-hook
  ```

  A config hook (it needs a git with config-based hooks, such as 2.55)
  runs before a repository's own `post-checkout`
  hook and doesn't replace it, so it works in repositories that have their
  own hooks, and it fires on `git clone` and `git worktree add` too.
  `core.hooksPath` is never touched. The command must be on `PATH`, e.g.
  through `nix profile install`.

Both are idempotent: when a file already says what it should, it isn't
written. When a file resolves into `/nix/store`, or isn't writable (a
Home Manager-managed `settings.json` or git config), `apply` changes
nothing in it, prints the JSON or the config lines to add where that file
is managed, and exits non-zero.

### `agent-skill-flake sync-project`

Run in a repository, it resolves the repository's effective `skills` by the
rules above and reconciles `<repo-root>/.agents/skills/` to exactly that
set, with the same machinery as [`reconcile`](#declarative-convergence-reconcilescript)
and the same [project-scope layout](#install-scope). Its entries are owned
by `agent-skill-flake-local`, so skills installed by anything else (a
dev shell, another installer, your own files) are left alone, and a skill
removed from the config is swept on the next run. Each skill is printed
with the installable it came from and the layer, `local` or `user-global`.

It exits 0 without output outside a git work tree, without an `origin`, or
when the repo has neither an entry nor a local file. A repository with its
own `skills-devshell/` is skipped with a one-line note, since its dev shell
owns its project skills.

With `--from-hook`, as the git hook runs it, it acts only on a branch
checkout (`post-checkout`'s third argument is `1`, which includes clone
and `git worktree add`), prints at most two lines, and always exits 0, so
it never fails a git command. Run it without `--from-hook` to see the
details of a failure.

The hook reads only the user-global config, never the checkout's own
`config.local.toml` (as `--ignore-local` does). A cloned repository can
commit that file, and the hook builds every installable its `skills`
name, so reading it would let `git clone` alone build and run code the
repository chose. A repository configured only by its local file syncs
when you run `sync-project` yourself.

### Ignoring the local file

`install`, `reconcile` and `sync-project` list
`/.config/agent-skill-flake/config.local.toml` in the repository's
`info/exclude` block. To cover repositories where none of them has run
yet, also add this line to your user-global git ignore file,
`~/.config/git/ignore`:

```gitignore
**/.config/agent-skill-flake/config.local.toml
```

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
pinned `agent-skill-flake`, not yours — defeating the `follows` and risking a
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
and the **`.agent-skill-flake-lock.json` entry** (so `uninstall` / `reap` /
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

### 7. Don't hand-edit `.agent-skill-flake-lock.json` or delete a GC root manually

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
- this target's GC-root records at
  `<gcroots-dir>/claude-skills/targets/<target-hash>/<name>` and its
  `.previous`, its flat roots `claude-skill-<target-hash>-<name>`, and
  every shared root no other target's record uses (other targets'
  records for the same skill, and any legacy `claude-skill-<name>` root,
  stay),
- the entry in `<target>/.agent-skill-flake-lock.json`.

An uninstall that can't get the GC-root layout's lock in time (see
[Default: symlink + GC root](#default-symlink--gc-root)) still removes
the symlink and the lock entry, but leaves the records, and so their
roots, until `prune-gc-roots` finds the skill no longer linked.

It refuses to touch entries it can't confidently identify as managed by
this agent-skill-flake lineage (the sentinel must say `managedBy=<this
lineage>`, or — if the symlink target has been GC'd — a GC root for it
must exist as a naming-convention fallback: the target's own record
`claude-skills/targets/<target-hash>/<name>` or flat root
`claude-skill-<target-hash>-<name>`, or a legacy `claude-skill-<name>`). A user's hand-rolled
`~/.claude/skills/foo` directory is therefore safe even if `foo`
happens to match a agent-skill-flake skill name.

For `--profile`-mode installs, `nix run .#uninstall` removes the
user-facing symlink + lock entry, but the entry stays in the Nix
profile. Run `nix profile remove` separately to drop it from the
profile.

## Retiring agent-skill-flake

Dropping a skill from a declared set is self-healing — `reconcile` owns the
entry by `appName` and sweeps it on the next run. Deleting the hook itself
is not: nothing tagged with its `appName` runs again, so its skills orphan.
To retire cleanly, clear the scope first. Either converge to empty while the
hook still exists (set `skills = [ ]` / `sources = [ ]`, keep it enabled —
in home-manager keep `enable = true;` and `switch` *before* deleting the
block, since `config` is gated on `enable`), or, once no hook is left, run
`purge`:

```sh
nix run github:nhooey/agent-skill-flake#purge -- --scope=personal   # clears ~/.claude/skills/
nix run github:nhooey/agent-skill-flake#purge -- --scope=project    # clears <repo>/.agents/skills/
nix run .#purge -- --scope=project --dry-run                   # list what would go; change nothing
nix run .#purge -- --scope=personal --yes                      # skip the confirmation prompt
```

`purge` removes every entry this lineage (`managedBy`) installed under the
scope — live or broken, any `appName`, no declared set or names needed — and
runs transiently off the bare flake when nothing is installed locally,
along with that scope's GC-root records, every shared root no record uses
any more, and any GC root whose store path is gone or, for a legacy
`claude-skill-<name>` root, covered by a target's current record. It
leaves other lineages and hand-rolled dirs alone, and confirms before
removing (`--dry-run`/`--yes` skip the prompt; non-interactive without either
refuses).

## Lock file

`<target>/.agent-skill-flake-lock.json` is a single-file index of every skill
this agent-skill-flake lineage has installed under that target. Same data as
the per-skill sentinels (`<target>/<name>/.agent-skill-flake-managed.json`),
indexed by name so you can `cat` it for an overview:

```json
{
  "schemaVersion": 1,
  "skills": {
    "garnix-ci": {
      "schemaVersion": 2,
      "managedBy": "github:nhooey/agent-skill-flake",
      "managedByRev": "abc123...",
      "managedByDirty": false,
      "managedByNarHash": "sha256-...",
      "skillName": "garnix-ci",
      "originalSkillName": "garnix-ci",
      "version": "0.1.0",
      "contentHash": "v1:sha256:8e51b0c6a2f9...",
      "storePath": "/nix/store/...-claude-skill-garnix-ci-0.1.0",
      "installedAt": "2026-04-27T12:34:56Z",
      "installedBy": "agent-skills-all"
    }
  },
  "satisfiedByPersonalScope": {
    "nix-flakes": {
      "personalCopy": "/home/me/.claude/skills/nix-flakes",
      "contentHash": "v1:sha256:3f0c2a91d4b7...",
      "checkedAt": "2026-04-27T12:34:56Z",
      "installedBy": "agent-skills-all"
    }
  }
}
```

`satisfiedByPersonalScope`, present only when it lists something, holds the
declared skills a project `reconcile` left to the personal scope's copy of
the same version, with that copy's path and their content hash (see
[A skill the personal scope already holds](#a-skill-the-personal-scope-already-holds)).
Such a skill has no `skills` entry, link, GC root or exclude line in the
project. Each reconcile rewrites the list from what it finds, and `purge`
clears it.

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
agent-skill-flake.lib.mkSkillFlake {
  inherit nixpkgs;
  skillName = "my-skill";
  src       = ./.;
  agent     = "codex";   # → installs at $HOME/.codex/skills/ for --scope=personal
}
```

Built-in profiles (see [`lib/agent-profiles.nix`](lib/agent-profiles.nix)):

| `agent`        | personal-scope (`$HOME/…`) | project-scope (`<root>/…`) |
|----------------|----------------------------|----------------------------|
| `claude-code`  | `.claude/skills`           | `.agents/skills` (linked from `.claude/skills`) |
| `codex`        | `.codex/skills`            | `.codex/skills`            |
| `cursor`       | `.cursor/skills`           | `.cursor/skills`           |

A profile's optional `projectLink` names a project-root path that
install and reconcile symlink to its project-scope directory. Its
`displayName` names the agent in reconcile's messages, and
`personalTakesPrecedence`, set for `claude-code`, lets the warning about a
skill that differs from the personal scope's copy say the agent uses the
personal one. To add a new
agent, append an entry to `lib/agent-profiles.nix`. An
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
- Replace `services.agent-skill-flake.installRoot` /
  `programs.agent-skill-flake.installRoot` module options with
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

[`nhooey/nix-skills`][nix-skills] uses `mkAllSkillsFlake` for its top-level
flake and `mkSkillFlake` for each per-skill flake. It is the reference
example of the multi-skill aggregation pattern.

## License

[Apache-2.0](LICENSE)
