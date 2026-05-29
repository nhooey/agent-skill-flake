---
name: gamma
description: Standalone fixture skill in tests/example-source-dir, used as a second upstream "source" flake for the aggregate-skills-flake checks.
---

# gamma

Minimal skill with a distinct name (not alpha/beta) so the aggregate merge
can assert a verbatim non-prefixed source contributes `skill-gamma` while its
`default` / aggregate keys are filtered out.
