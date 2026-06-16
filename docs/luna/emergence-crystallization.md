# Emergence → self-improvement crystallization — PARKED design (HIMMEL-217)

> **PARKED, not built.** This records the design for a triggered
> emergence-to-improvement pass so the idea survives parking (operator
> decision Q4=b: "park but document") and a future session can implement
> it without re-deriving. No skill/hook/code exists for this yet — see
> **Status** at the bottom.

## Why (the gap)

The vault already self-maintains: `obsidian-ingest` wires in self-links and
`wiki-lint` keeps the link graph healthy, while `obsidian-emerge` and
`synthesize-clips` surface recurring patterns into synthesis/concept
**pages**. What is missing is a triggered step that crystallizes an
emerging cluster into **derived self-improvement** — candidate
capabilities and action items for himmel + luna — beyond a lesson-learned
note. Patterns accumulate silently and never become work: the knowledge
lands, but nothing turns "we keep hitting this theme" into a proposed
ticket.

## The triggered pass

A pass that runs on a trigger (not every session) and walks an emerging
cluster from detection through to deduped self-improvement proposals.

**Trigger.** Scheduled (e.g. weekly) **or** threshold (after N new ingests
touching a theme). Deliberately not per-session — this is a batch
maintenance sweep, like `synthesize-clips`.

**Detect.** Emerging clusters = themes recurring across recent ingests, or
newly dense neighborhoods in the link graph. Build on `obsidian-emerge` +
`synthesize-clips` for detection; do not reinvent pattern-surfacing.

**Crystallize — both outputs.** For each *relevant* cluster, emit BOTH:
- **(a)** a synthesis/lesson concept page (the existing behavior), AND
- **(b)** **derived self-improvement action items** — candidate tickets /
  capabilities — deduped against open Jira by reusing the `roadmap-clips`
  dedup (LUNA-59).

**Relevance gate (the key novel piece).** The vault is broadening into a
general second-brain, so most clusters are pure knowledge with no
claude-work action attached — a cluster on, say, a domain concept the
operator is studying should stay a wiki concept and must NOT manufacture a
ticket. The gate decides which clusters reach output (b):
- Clusters about **our tooling / workflow / agent-practice** (himmel
  hooks, skills, the luna pipeline, how Claude is run/orchestrated) →
  emit self-improvement items.
- **Pure-knowledge / personal** clusters → stay wiki concepts only; no
  self-improvement items.

Define and tune the heuristic during the build (signals: proximity to
tooling/agent-practice entities and existing himmel/luna concept pages,
presence of capability/verb-shaped phrasing vs. descriptive knowledge,
operator-correctable false positives). **Err toward NOT manufacturing
busywork** — a missed real item is cheap (it recurs and re-triggers next
pass); a fabricated ticket costs operator triage and erodes trust in the
proposal list.

**Human-in-loop.** Output (b) is **proposals only**. The operator promotes
a candidate to a real ticket; the pass never files Jira issues itself.

## Relations & routing

- **Extends HIMMEL-216** (derive-action-items loop). 216 is the *one-time*
  inventory review; **217 is the ongoing, emergence-driven feeder** that
  keeps supplying candidates as the vault grows. 217 is the recurring
  engine; 216 was the initial sweep.
- **Builds on** `roadmap-clips` (LUNA-59, for the open-Jira dedup),
  `obsidian-emerge`, and `obsidian-synthesize` / `synthesize-clips` (for
  detection + the synthesis-page output). **Complements** `wiki-lint`
  (lint keeps the graph healthy; this pass reads the graph it maintains).
- **Routing of self-improvement candidates** (once the operator promotes
  them, and as a hint on each proposal):
  - **Tool installs** → HIMMEL-199 (the tool-adoption framework /
    rubric+registry).
  - **Memory / context** clusters → LUNA-44.

## Eventual build DoD

Record these as the future build's definition of done (acceptance of the
eventual feature):
- A triggered pass emits synthesis pages for emerging clusters **and** a
  deduped list of derived self-improvement candidates.
- The relevance gate **demonstrably** filters pure-knowledge clusters out
  of the self-improvement list (no busywork tickets).
- Dedup vs. open Jira works — no re-proposing existing tickets.
- Proposals-only, human-in-loop — the pass never files tickets itself.

## Status

**PARKED** per HIMMEL-217, operator decision Q4=b ("park but document").
Not built; build later. This doc is the captured intent so the future
session implements from here rather than re-deriving.
