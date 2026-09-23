# The `ponytail:` convention

`ponytail:` is a code-comment marker for a known, deliberate simplification —
written at the exact line where a reader would otherwise mistake the partial
behavior for the complete one. It exists so "we simplified this on purpose"
is attached to the code, not left to survive only in a PR description or
someone's memory.

This is [upstream DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail)'s
convention, not a homegrown one — we adopted the marker text but, until
HIMMEL-3511, neither credited it nor used its full shape. Upstream's own
`/ponytail-debt` skill (`skills/ponytail-debt/SKILL.md` in the installed
plugin, `~/.claude/plugins/marketplaces/ponytail/`) is what makes the shape
below load-bearing: it harvests every marker into a ledger and tags any that
lack the second half as `no-trigger` — "the ones that silently rot."

## Shape

```
ponytail: <ceiling>, <upgrade path>
```

Both halves are required on a **new** marker:

- **Ceiling** — what the code does *not* do or guarantee, stated
  concretely. "Shape-based, so an unnamed or multi-word credential still gets
  through" (`run-hook-with-bash.js:306`), "AT-LEAST-ONCE, not
  exactly-once" (`stop-queue.mjs:53`). A marker that only gestures at a
  simplification ("this is simplified") without naming the limitation is not
  a conforming use.
- **Upgrade path** — the trigger or ticket that would justify revisiting the
  ceiling: a HIMMEL key, or a concrete condition ("upgrade to per-URL locking
  if throughput ever makes that a bottleneck",
  `scripts/handover/artifact-sync.sh:72`). "None planned, because X" is a
  valid upgrade path — it is a decision, not silence. What's not valid is
  leaving the second half off entirely.

Upstream's own illustration uses an HTML comment (`<!-- ponytail: browser has
one -->`) specifically so its README doesn't pollute its own ledger; that's a
formatting trick, not part of the convention.

- **Prefix.** A `#` or `//` line comment starting with `ponytail:` is the
  dominant shape in this repo.
- **Placement.** Directly on, or immediately above, the code exhibiting the
  simplification, in the same file — never centralized in a doc or a
  tracking issue.
- **Subject matter.** Runtime/algorithmic behavior a reviewer could
  otherwise assume is complete — a check that isn't exhaustive, a lock that
  doesn't cover a case, a comparison that's a prefix match. Not style
  commentary, not a TODO, not a changelog note.

## Where we stand today

`docs/internals/ponytail-debt.md` is the harvested ledger, generated with
upstream's method (`grep -rnE '(#|//) ?ponytail:' .`, skipping
`node_modules`/`.git`/build output). Most existing markers predate this
rewrite and name only a ceiling; the ledger's `no-trigger` count is that
backlog, not a new problem this doc created. Backfilling triggers onto
existing markers is phase 2 (tracked in HIMMEL-3511's follow-up, not this
PR) — this PR does not retro-edit any existing marker.

## Enforcement layer: documentation only, for now

Per `CLAUDE.md`'s "Adding a rule — pick the cheapest layer": escalate to a
structural gate only on the **second** drift instance, never on the first.
Requiring the upgrade-path half on new markers is itself the first
correction here — there is no prior documented instance of someone gaming
*that* requirement to escalate from. The honest read of the evidence is:
document the fuller shape, do not gate it yet.

**What would count as the second drift instance**, i.e. what would justify
adding a gate: a newly added `ponytail:` marker missing the upgrade-path
half, or naming one that just gestures without a real trigger or ticket. If
that happens, the shippable shape is a check scoped to **added** lines only
(new markers via the changed hunks) — it must never fire on pre-existing
markers, which would make it noise from day one and get it disabled within a
day.

## Writing a new one

Before writing `ponytail:`, consider whether the simplification should just
be fixed instead. If not, write the marker at the site, naming the concrete
limitation and the upgrade path — not merely that a limitation exists.

Run upstream's `/ponytail-debt` (or regenerate
`docs/internals/ponytail-debt.md` the same way) whenever you want the
current backlog, rather than trusting a stale ledger snapshot.
