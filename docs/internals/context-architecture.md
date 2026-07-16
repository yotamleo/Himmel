# Context architecture — the lean-surface doctrine

Canonical reference for **where knowledge lives** in himmel so the
always-loaded surface stays small. Every token in `CLAUDE.md`, `MEMORY.md`,
an enabled plugin's catalog, or a loaded skill is paid **in every session** —
and again in **every subagent context**. The discipline here keeps that fixed
cost low without losing the knowledge: push detail to layers that load **on
demand**, and make retrieval — not always-loaded prose — the default.

This doc is the anchor. The operating rules that reference it —
[`CLAUDE.md`](../../CLAUDE.md) (the layer-selection frame, HIMMEL-177 /
HIMMEL-195), [`operator-conventions.md`](../operator-conventions.md#memory--claudemd-hygiene)
(the habits), and [`enforcement.md`](enforcement.md#operator-conventions--worked-examples)
(worked escalation examples) — point here rather than restating it.

## The four converging rules

Distilled from a multi-author synthesis of the "CLAUDE.md patterns" corpus:

1. **Short beats long.** A shorter always-loaded file is read; a long one is
   skimmed and then ignored — by both the operator and the model. Length erodes
   the authority of every rule in the file.
2. **Nested beats one giant file.** Scope knowledge to where it applies (see
   the layering model) instead of piling it into one root file.
3. **State, not a prompt.** The root file is repo *memory* — why / map / rules /
   workflows — not a personality or a coding-philosophy essay. Anything
   derivable from the code, git, or the README does not belong in it.
4. **Spend the first dollar of leverage.** Optimize the highest-frequency,
   always-paid surface first (root file size, enabled-plugin count) before
   micro-tuning rarely-loaded layers.

**Anti-patterns to keep out of the always-loaded surface:** coding philosophy,
architecture summaries (→ README), generic style guidance, codebase-derivable
facts, and anything that contradicts another file.

## The layering model — where each thing lands

Pick the **cheapest layer that still fires when needed**. The always-loaded
root is the most expensive layer; use it only for what must shape every task.

| Content type | Lands in | Loads |
|---|---|---|
| Frame-shaping, **cross-cutting** rules | root `CLAUDE.md` (kept lean) | always |
| Domain-local **dev** conventions | nested subtree `CLAUDE.md` | only when working in that subtree |
| Cross-cutting **operational** ("when stuck") rules | a load-on-trigger skill / `docs/internals/` playbook | on the symptom |
| Reference detail | `docs/` via a pointer | on demand |
| Safety-critical rules | a **structural** hook / pre-commit / pre-push gate | enforced, not remembered |
| Durable facts (memory) | compounded into a searchable substrate; slim index | on query |

### The nesting trap (the rule that reshapes rule 2)

A subtree `CLAUDE.md` loads **only when the model is working inside that
subtree**. That makes nesting exactly right for **domain-local dev
conventions** (e.g. Jira-CLI invocation rules under `scripts/jira/`) — and
exactly **wrong** for **cross-cutting operational rules**. Push a rule that
applies to *every* session (a shell-command-shape rule, a "prefer X over Y"
routing rule) into a subtree and **it stops firing** the moment you are editing
elsewhere.

So:

- **Domain-local → subtree `CLAUDE.md`.** Fires where it's relevant, costs
  nothing elsewhere.
- **Cross-cutting operational → load-on-trigger skill**, not a subtree. Fires
  on the symptom (a denial, a friction point) regardless of cwd. This is why
  operational "when stuck" detail is kept out of both the root file *and* the
  subtree files.
- **Cross-cutting frame-shaping → the root file**, kept short.
- **Safety-critical → a structural gate.** Prose does not enforce; on the
  second drift of an instructional rule, escalate it to a hook/gate rather than
  writing stronger prose (HIMMEL-195).

## Memory as a map, not a backend

The same principle applies to durable facts. The always-loaded memory index is
the **map** — one line per fact, pulled by relevance — while the facts
themselves live in a searchable substrate and are retrieved by query. When the
index nears its load budget, compound the durable facts out into the substrate
and slim the index (himmel does this via the `memory-compound` skill,
HIMMEL-569); the index never becomes the store.

Two guards keep retrieval honest:

- **Curate the map.** Pure semantic retrieval *structurally forgets* — an
  un-curated index silently drops what it can't surface. The index must be
  maintained, not dumped into.
- **Mark staleness.** A recalled fact reflects what was true when written. The
  memory layer supports *optional* `confidence` + `verified:` markers (defined in
  [`operator-conventions.md`](../operator-conventions.md#memory--claudemd-hygiene));
  the invariant — required with or without those markers — is that when a recalled
  fact is found stale, you re-check and update it (or delete it), never act on a
  stale claim silently.

## Where the canonical pieces live

- **Layer-selection frame** (lean-invoke vs default-rule vs default-hook vs
  defer) + **structural > instructional** escalation → [`CLAUDE.md`](../../CLAUDE.md)
  (HIMMEL-177 / HIMMEL-195).
- **The habits** (no operational rules in the root, verify universal claims,
  generic example names, specs live in the state repo, memory staleness
  frontmatter) → [`operator-conventions.md`](../operator-conventions.md#memory--claudemd-hygiene).
- **Worked escalation examples** (an instructional rule hardening into a
  structural gate) → [`enforcement.md`](enforcement.md#operator-conventions--worked-examples).
- **The always-on enforcement surface** (hooks + gates) → [`enforcement.md`](enforcement.md).

## Maintenance — the surface re-accretes

The lean surface is not self-sustaining: rules pile back onto the root file over
time. Treat root-file growth as debt. Before adding anything to the
always-loaded surface, ask which row of the layering table it belongs to — the
answer is rarely the root file. When reference detail already exists in a
`docs/` file, the root should carry a **pointer**, not a copy.
