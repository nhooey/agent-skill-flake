# Plan: declarative dev-shell convergence for `mkAggregateSkillsFlake`

Status: proposed
Author: derived from the `skills-git` consumer (authoring-skills dev shell)
Scope: `lib/mk-aggregate-skills-flake.nix` (combined installer + reconcile),
`lib/marketplace.nix` + `lib/internal.nix` (appName-scoped ownership tagging
in the installer/reconcile/lock), `README.md`. Additive; existing per-source
helpers and apps keep working.

## Motivation

A "marketplace" consumer wires `mkAggregateSkillsFlake` into a dev shell so
`nix develop` installs its skills. Today that is **not declarative**: the
shell re-converges by *adding*, never by *removing*.

`installScript` emits one `install` line per source:

```
install-agent-skills-all          --scope=project                 # base (./skills)
install-agent-skills-all          --scope=project nix-flakes …     # a source subset
install-humanizer                 --scope=project
install-agent-skills-anthropic-all   --scope=project
install-agent-skills-superpowers-all --scope=project
```

`install` only adds/updates its own symlinks. When a skill is **renamed or
dropped** from the declared set, its old symlink lingers. Real example from
`skills-git`: after superpowers skills were given a `superpowers-` prefix, the
target dir kept both the new `superpowers-brainstorming` *and* the stale
un-prefixed `brainstorming` from the previous shell entry — plus a stale
`skill-creator` next to the new `anthropic-skill-creator`.

The obvious fix — run `reconcile` ("install declared set, sweep strays") —
**cannot** be composed across these lines. Every skill in the target shares
one `flake-skills` managed-by lineage (all sources `follows` the consumer's
`flake-skills`). `reconcile` deletes every entry of that lineage not in *its*
declared set. So if any one of the five installers reconciled, it would delete
the four others' skills as "strays". Five reconciles would thrash, each
sweeping the previous one's work.

The root cause is **ownership**: `reconcile` is a whole-target, single-owner
operation, but the dev shell has five owners and none knows the union of what
is declared. To be declarative, one owner must reconcile the target to the
union of everything the aggregate declares.

`mkAggregateSkillsFlake` is the right place to fix this because it *already*
computes that union (it merges every source into one package set) — it just
doesn't install through it.

## Goal

`nix develop` (or `nix run .#reconcile`) converges the target
`.claude/skills/` to **exactly** the union of all aggregated skills: install
missing, update changed, remove strays. Idempotent, no drift, no manual
`uninstall`/`reap`. The result is a pure function of the flake inputs.

## Design

### 1. Build one combined installer over the union

The data already exists. `packagesForSource` / `upstreamPackagesFor` yield
`{ name → drv }` for every source — prefix-wrapped via `withNamePrefixSource`
where `prefix` is set, filtered-by-`packagePrefix` otherwise — and `base`
contributes its own skills. Collect all of them as one
`[ { name; drv; } ]` list (the same shape `withNamePrefixSource` already
returns and `mkInstaller` already consumes), then build a single installer:

```nix
combined = mkInstaller {
  inherit nixpkgs system agent;
  appName = name;                 # the aggregate's name, e.g. "agent-skills-all"
  skills  = unionRecords;         # base + every source, prefixed as declared
};
```

`mkInstaller` over an already-wrapped set is exactly what `mkPrefixedInstaller`
does internally, so prefixed and unprefixed skills compose with no new wrapping
logic. The only refactor is to have `packagesForSource` expose its result as
`[ { name; drv; } ]` records (it already keys them by name internally) so both
the `packages` merge and the installer can consume the same source of truth.

### 2. Expose aggregate apps + a reconcile script

```nix
apps.<system> = {
  inherit (combined) install uninstall preview reap reconcile;
};
reconcileScript = system: "${combined}/bin/reconcile-${name} --scope=project";
# installScript stays (additive, back-compat) but the README points consumers
# at reconcileScript for dev shells.
```

The dev-shell startup collapses to one line:

```nix
devshell.startup.install-skills.text = agg.reconcileScript system;
```

This answers the open question carried in
`marketplace-convenience-functions.md` ("should `mkAggregateSkillsFlake` also
emit a combined `install` app?") — yes, and the dev-shell default should be
`reconcile`, not `install`, because only `reconcile` is declarative.

### 3. Why this is safe where per-source reconcile was not

There is now a single declared set (the union) and a single owner (the
`combined` installer) of the target. `reconcile`'s contract — "install my
declared set, delete every managed entry not in it" — is exactly correct: the
"managed entries not in my set" are precisely the renamed/removed strays
(`brainstorming`, `skill-creator`, …). No sibling can be mistaken for a stray
because every sibling *is* in the declared set.

### 4. appName-scoped ownership (composability refinement)

A whole-lineage reconcile claims the **entire** target dir for the
`flake-skills` lineage: if a consumer also installs other
flake-skills-managed skills into the same `.claude/skills/` by other means,
this reconcile would sweep them. Two ways to define the contract:

- **Strict (no code change):** document that one `mkAggregateSkillsFlake` owns
  its target dir. Simple; the common case.
- **Scoped (preferred):** tag each lock entry / `.flake-skills-managed.json`
  sentinel with the installer's `appName`, and have `reconcile` sweep only
  strays bearing *its own* `appName`. The lock already records per-skill
  provenance, so this is a small field addition in
  `internal.nix`'s installer + reconcile. Then "declarative" means *this
  aggregate's slice* converges, and multiple aggregates (or a hand-rolled
  installer) can coexist in one dir, each declaratively owning its subset.

Recommend shipping the scoped variant: it preserves the composability that the
marketplace helpers were created for, and keeps the strict case as the
degenerate single-owner instance.

## File-by-file changes

- `lib/mk-aggregate-skills-flake.nix`
  - Have `packagesForSource` return `[ { name; drv; } ]` records (single
    source of truth); derive both the `packages` merge and the union list from
    it. Add `base`'s skills to the union.
  - Build `combined = mkInstaller { … skills = union; appName = name; }`.
  - Add `combined`'s apps to the returned `apps.<system>` and add
    `reconcileScript = system: "…/bin/reconcile-${name} --scope=project"`.
  - Keep `installScript` for back-compat.
- `lib/marketplace.nix` / `lib/internal.nix` (scoped variant only)
  - Thread an `owner`/`appName` tag through `mkInstaller` into the lock entry
    and sentinel; scope `reconcile`'s stray-sweep to entries with a matching
    tag. Untagged legacy entries: sweep under the strict rule or leave to
    `reap` — decide in review.
- `README.md`
  - Under "Marketplace / aggregation": document `apps.reconcile` +
    `reconcileScript`, and state that the dev-shell pattern should call
    `reconcileScript` (declarative) rather than hand-joining `install` lines.
    Cross-link the "wrong ways to install" pitfalls (separate plan).

## Testing

Extend the bats-over-fixtures suite (`tests/checks/`), reusing `fixtureAll`
plus a second synthesized source:

- **Convergence:** install the union, then rebuild the aggregate with one
  source renamed/removed; `reconcile` leaves exactly the new union — the
  renamed-away name is gone, nothing else is. This is the regression test for
  the `skills-git` stray-leftover bug.
- **Idempotence:** `reconcile` twice in a row → second run is a no-op (no
  symlink churn, exit 0), matching the silent-no-op behavior from #13.
- **Coexistence (scoped variant):** two aggregates with different `appName`s
  installing into one target; each `reconcile` sweeps only its own strays and
  never the other's skills.
- Wire each into `checks.nix` so `nix flake check` covers them.

## Backward compatibility

Additive. `installScript`, the per-source helpers (`installCommandFor`,
`mkPrefixedInstaller`, `withNamePrefixSource`, `mkInstaller`) and existing app
names are unchanged. A consumer keeps working until it opts into
`reconcileScript`. The scoped-ownership tag is a new, optional lock field;
entries without it fall back to lineage-scoped behavior.

## Relation to existing work

- Closes the "combined install app?" open question in
  `marketplace-convenience-functions.md` — with the stronger answer that the
  combined app must include `reconcile` and the dev-shell default should be it.
- Brings the dev-shell path to **parity** with the home-manager / nix-darwin
  modules, which already reconcile the declared set on activation (via the
  `passthru.isFlakeSkillsEnv` / `flakeSkillsEnv` records). The imperative
  install-on-shell-entry path was the only non-declarative surface left.

## Open questions

- Strict vs scoped ownership for v1 (recommend scoped).
- Should `reconcileScript` accept a `scope` argument (default `project`) the
  way `installCommandFor` does, for personal-scope dev shells?
- Legacy untagged lock entries under the scoped variant: sweep, or require a
  one-time `reap`/migration? Leaning "sweep under strict rule on first scoped
  reconcile, then tag," but it needs a regression test either way.
- Should `installScript` be deprecated (kept, but documented as non-declarative
  and discouraged) or left as a peer option for consumers that deliberately
  want additive-only behavior?
