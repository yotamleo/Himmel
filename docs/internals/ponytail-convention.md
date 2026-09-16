# The `ponytail:` convention

`ponytail:` is a code-comment marker for a known, deliberate simplification —
written at the exact line where a reader would otherwise mistake the partial
behavior for the complete one. It exists so "we simplified this on purpose"
is attached to the code, not left to survive only in a PR description or
someone's memory.

Before this doc, the convention was undocumented and unenforced: 37 sites in
`scripts/` (`grep -rio 'ponytail' scripts/ | wc -l`, re-derived 2026-09-17;
zero hits under `docs/`, `CLAUDE.md`, `.claude/`). It survived by imitation
alone. This doc records what those 37 sites actually do, derived from
reading them — it does not redesign the convention.

## Shape, as used today

- **Prefix.** `# ponytail:` / `// ponytail:` at the start of the comment line
  is the dominant shape (35 of 37 sites). Two sites diverge and are left
  as-is (this ticket documents, it does not retro-edit the existing 37):
  `scripts/sync/repo-sync-runner.sh:559` puts `ponytail:` mid-comment after
  other prose, and `scripts/hooks/require-quiet-run.sh:119` references
  "ponytail" in prose to describe a *former* note rather than writing a live
  one.
- **Content is contrastive.** Every conforming site states what the code
  does and then explicitly what it does **not** do or guarantee — "shape-based,
  so an unnamed... credential ... " (`run-hook-with-bash.js:303`),
  "AT-LEAST-ONCE, not exactly-once" (`stop-queue.mjs:53`), "hashes only the
  LOCAL file — it cannot independently..." (`artifact-sync.sh:115`). A
  marker that only gestures at a simplification ("this is simplified")
  without naming the limitation is not a conforming use — none of the 37
  sites actually does this, which is itself evidence for what the
  convention requires.
- **Placement.** Directly on, or immediately above, the code exhibiting the
  simplification, in the same file — never centralized in a doc or a
  tracking issue.
- **Subject matter.** Runtime/algorithmic behavior a reviewer could
  otherwise assume is complete — a check that isn't exhaustive, a lock that
  doesn't cover a case, a comparison that's a prefix match. Not style
  commentary, not a TODO, not a changelog note.

## What it does NOT include today

- **No ticket reference.** None of the 37 sites link to a Jira ticket, so
  there is no structural path from "we simplified this" to "we fixed it" or
  "we decided not to" — a simplification can sit unrevisited indefinitely.
  This is a real gap; this ticket documents it rather than closing it.
- **No enforcement.** Nothing checks the shape, and nothing requires a
  marker when a shortcut is taken. The convention is entirely honor-system.

## Enforcement layer: documentation only, for now

Per `CLAUDE.md`'s "Adding a rule — pick the cheapest layer": escalate to a
structural gate only on the **second** drift instance, never on the first.
This ticket *is* the first time the convention has been examined at all —
there is no prior documented instance to escalate from — and the 37 existing
sites are consistent enough (module the two stragglers above, both
harmless) that the convention is evidently holding on imitation alone. The
honest read of the evidence is: document it, do not gate it yet.

**What would count as the second drift instance**, i.e. what would justify
adding a gate: a newly added `ponytail:` marker that gestures without naming
a concrete limitation, or one used to wave through a shortcut nobody
reviewed. If that happens, the shippable shape is a check scoped to **added**
lines only (`git diff` on the changed hunks, `--diff-filter=A` equivalent for
new markers) — it must never fire on the pre-existing 37 sites, which would
make it noise from day one and get it disabled within a day.

## Writing a new one

Before writing `ponytail:`, consider whether the simplification should just
be fixed instead. If not, write the marker at the site, naming the concrete
limitation — not merely that one exists.
