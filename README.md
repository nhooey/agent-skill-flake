# flake-skills

A tiny Nix flake providing `lib.mkSkillFlake`: a function that builds an
installable Nix flake from a [Claude Code agent-skill][skills] directory.

Use it from a per-skill repo (or a per-skill flake within a multi-skill repo
like [`nhooey/skills-nix`][skills-nix]) to skip the boilerplate of wiring up
`packages` / `apps` / install / preview by hand.

[skills]: https://www.anthropic.com/engineering/agent-skills
[skills-nix]: https://github.com/nhooey/skills-nix

## Consumer example

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
nix build .#my-skill            # produce $out/share/claude-skills/my-skill/
```

The default `nix run` is the **preview** — it lists the files that would be
installed and the target path, but writes nothing. The explicit `#install`
app is the only one with side effects.

## API

```nix
flake-skills.lib.mkSkillFlake {
  nixpkgs        = <flake input>;
  skillName      = "my-skill";
  src            = ./.;
  # optional:
  systems        = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
  description    = "Claude Code skill: my-skill";
  version        = "0.1.0";
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
    default = { type = "app"; program = "<preview>"; };
    install = { type = "app"; program = "<install>"; };
    preview = { type = "app"; program = "<preview>"; };
  });
}
```

## Build behavior

The skill derivation produces:

```
$out/share/claude-skills/<skillName>/
├── SKILL.md          # required, mode 644
├── references/       # copied recursively if present
└── scripts/          # copied recursively if present
```

Everything else in `src` is ignored — including `flake.nix`, `flake.lock`,
hidden dotfiles, and any other top-level files. If you need to ship more than
`SKILL.md`, `references/`, and `scripts/`, this lib is not the right tool.

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

The Nix-native install. Two things happen:

1. **User-facing symlink.**
   `${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/<skillName>` is created as a
   symlink to `<store-path>/share/claude-skills/<skillName>`. Claude Code
   follows it transparently.
2. **Per-user GC root.**
   `/nix/var/nix/gcroots/per-user/$USER/claude-skill-<skillName>` is created as
   a symlink to the store derivation. This protects the store path from
   `nix-store --gc`. Override the gcroots dir with `NIX_GCROOTS_DIR` (used by
   the test suite; rarely useful in practice).

The user-facing symlink is read-only by virtue of pointing into the store. To
**upgrade** a skill, re-run `nix run .#install`: the symlink is replaced
atomically, the new store path becomes the GC root, the old path becomes
GC-eligible.

To **uninstall**:

```sh
rm ~/.claude/skills/<skillName>
rm /nix/var/nix/gcroots/per-user/$USER/claude-skill-<skillName>
```

(The first `rm` is enough to make Claude Code stop seeing the skill; the
second is what releases the store path for GC.)

### `--profile`: via `nix profile install`

If you want skills to participate in the `nix profile` machinery
(`list`/`upgrade`/`rollback`/`remove`):

```sh
nix run .#install -- --profile
```

This calls `nix profile install <store-path>`, then symlinks
`~/.claude/skills/<skillName>` into `~/.nix-profile/share/claude-skills/`.
GC protection comes from the profile itself; no separate GC root.

To **upgrade** in this mode: `nix profile upgrade --regex 'claude-skill-<name>'`.
To **uninstall**: `nix profile remove ...` AND `rm ~/.claude/skills/<name>`
(both — the symlink lives outside the profile).

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

The lib is exported as `lib.mkSkillFlake`. Consumers should pin via
`flake.lock`. If a breaking change is ever needed, a new entry point will be
added (e.g. `lib.v2.mkSkillFlake`) rather than mutating `lib.mkSkillFlake` in
place.

## Multi-skill repos

This flake is single-purpose: one function, one skill per call. To aggregate
many skills into one derivation (or one installer that drops them all in at
once), see [`nhooey/skills-nix`][skills-nix]'s top-level `flake.nix` for the
`symlinkJoin` pattern. That repo is the canonical consumer of `flake-skills`
and a good starting point for a new multi-skill repo.

## License

[Apache-2.0](LICENSE)
