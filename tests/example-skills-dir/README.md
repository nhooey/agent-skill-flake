# example-skills-dir

Fixture used by `nix flake check` to validate `lib.mkAllSkillsFlake`.

Layout:

```
example-skills-dir/
├── alpha/SKILL.md           # minimal skill
├── beta/                    # skill with references/ + scripts/
│   ├── SKILL.md
│   ├── references/notes.md
│   ├── scripts/run.sh
│   └── .hidden              # filtered out at build time
├── not-a-skill/             # no SKILL.md → not discovered
│   └── README.md
└── README.md                # ignored by discovery (top-level file)
```
