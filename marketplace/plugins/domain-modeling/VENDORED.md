# Vendored files in domain-modeling@himmel

Inventory for domain-modeling@himmel (HIMMEL-5498). Source: `mattpocock/skills`,
pinned at `49dd158d1076134a641b33efb035946536778336`, path
`skills/engineering/domain-modeling/`, MIT, (c) 2026 Matt Pocock. Fetched
2026-10-16; first vendored under `.claude/skills/domain-modeling/`, moved into
this plugin so a profile can select it.

| path | upstream path | deviation |
|---|---|---|
| `skills/domain-modeling/SKILL.md` | `SKILL.md` | output retargeted from a root `GLOSSARY.md` to himmel's `docs/glossary.md`; multi-context `GLOSSARY-MAP.md` structure and ADR guidance dropped; frontmatter `description` trimmed; a header under the frontmatter names source, sha and these deviations |
| `skills/domain-modeling/GLOSSARY-FORMAT.md` | `GLOSSARY-FORMAT.md` | retargeted at `docs/glossary.md` and its table format; header names source and sha |
| `LICENSE` | `LICENSE` | none (verbatim) |

Not vendored: `ADR-FORMAT.md` (himmel keeps decision records in the state repo)
and the upstream `grill-with-docs` wrapper. The manifest and README here are
himmel's own.

Re-sync: diff the two skill files against the pinned upstream path, re-apply
the deviations, update the sha here, in both headers, in
`docs/third-party-licenses.md`, in `scripts/lint/test-vendored-domain-modeling.sh`
and in `scripts/lanes/tests/domain-modeling-plugin.test.mjs`.
