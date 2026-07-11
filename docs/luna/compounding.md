# Luna Compounding Loop

Your vault compounds value automatically — each stage in the pipeline
transforms raw session output into structured knowledge, and that knowledge
feeds the next stage. This document describes the loop, what each stage
adds, the recommended cadence, and how to seed the vault with historical
sessions.

There are **two complementary compounding loops**, and they feed different
kinds of knowledge into the same vault:

1. **The clips / session-capture loop** (most of this document) — turns raw
   session output and inbox clips into triaged, synthesized vault content.
2. **The auto-memory → vault loop** ([below](#a-second-loop-auto-memory--vault))
   — periodically distils Claude Code's own per-project *auto-memory* (the
   always-loaded `MEMORY.md` index plus its topic files) into searchable vault
   reference notes, so durable learnings survive while the always-loaded index
   stays lean.

## The loop

```
Capture → Triage → Synthesize → (Backfill for history)
   ↑                                        |
   └────────────── vault grows ─────────────┘
```

### Stage 1 — Capture (automatic)

Every Claude Code session ends by writing a structured note into the vault
(`sessions/YYYY/MM/`). The `end-session-wiki` hook runs on every
`SessionEnd` event; no action required. Notes contain:

- Frontmatter: repo, branch, timestamp, `duration_minutes`, `files_touched`
- Summary, Decisions, Commands, Follow-ups extracted from the transcript
- `source: live` (distinguishes from backfill)

Full schema: [`end-session-wiki-schema.md`](./end-session-wiki-schema.md).
Vault target config: [`end-session-wiki.md`](./end-session-wiki.md).

### Stage 2 — Triage

The `Clippings/` inbox accumulates items from all sources (URLs, Telegram
clips, luna-ingest). Triage summarizes, tags, extracts action items into the
daily note, and flags promotion candidates.

- **Entry point:** `/triage-clips` (from the obsidian-triage plugin)
- **Idempotent:** re-running is safe; already-processed clips are skipped.

### Stage 3 — Synthesize

Cross-clip synthesis finds recurring patterns across processed clips and
writes proposal pages to `Clippings/_synthesis/`. Proposals only — it never
restructures the vault.

- **Entry point:** `/synthesize-clips`
- **Cadence:** weekly (after a batch of triage runs gives it enough to work with)

### Stage 4 — Archive

Fully-chained clips (harvested + processed + in-synthesis) are graduated to
`Clippings/_done/<YYYY-MM>/`, inbound links are rewritten, and
`Clippings/_deferred.md` is regenerated.

- **Entry point:** `/archive-clips`

## Recommended cadence

Use `/pipeline-cadence` to arm the OS scheduler for the standard
cadence:

| Frequency | Stages | Command |
|-----------|--------|---------|
| Daily | Harvest + Triage | `/harvest-clips` → `/triage-clips` |
| Weekly | Synthesize + Archive | `/synthesize-clips` → `/archive-clips` |
| Monthly | Vault health | `/obsidian-health` |

Run `/pipeline-cadence status` to see current scheduler state, or
`/pipeline-cadence arm` to set it up.

## Seed your vault with historical sessions

If you have existing Claude Code sessions from before the vault was set up,
use `/luna-backfill` to import them. Each transcript is rendered using the
same schema as the live capture hook.

> **Token-usage caveat:** Backfill seeds many notes at once. Running
> `/triage-clips` or `/synthesize-clips` immediately after a large backfill
> can cost significant tokens — proportional to how many sessions were
> imported. Dry-run first and batch if the count is large.

Recommended steps:

1. **Dry-run** — check counts before writing anything:
   ```bash
   /luna-backfill --dry-run
   ```
2. **Scope** — start with the current project (default), then expand to
   `--all` once you are comfortable with the output.
3. **Import** — write the notes:
   ```bash
   /luna-backfill
   ```
4. **Triage** — run the triage pipeline over the new notes:
   ```bash
   /triage-clips
   ```

Full flag reference: [`/luna-backfill`](../../.claude/commands/luna-backfill.md)
(or type `/luna-backfill --help` in a Claude Code session).

## A second loop: auto-memory → vault

Claude Code keeps a per-project **auto-memory** store
(`~/.claude/projects/<project-slug>/memory/`): a `MEMORY.md` index that is
loaded into context *every session*, plus one topic file per remembered fact.
It grows by itself — each session that learns something durable (a gotcha, a
preference, a project decision) appends an entry. That is exactly what makes it
valuable *and* what eventually makes it a liability: an index that is paid for
on every single turn cannot grow without bound. Left alone it bloats past its
size budget, and once it is too long it stops being read — by you and by Claude.

The fix is the same compounding move the clips loop makes, pointed at a
different source. **Periodically distil the auto-memory into the vault:**

1. **Mine** each topic file for the *durable* learning it carries — the
   reusable gotcha or decision — as distinct from ephemeral status (PR numbers,
   "merged", ticket state, dates). Status is already recoverable from your issue
   tracker, git history, and the session captures in `sessions/`.
2. **Land** that learning where it propagates. First classify it (the
   propagation review — memory and the vault are operator-side only, no other
   user ever sees them): an **operator-specific** learning goes to a vault
   reference note under `30-Resources/Tech/` (grouped by theme — environment
   traps, harness gotchas, operator conventions, …) so it becomes
   [qmd](../tooling-catalog.md)-searchable substrate rather than always-loaded
   weight; an **adopter-generic** learning (true for anyone running himmel)
   goes to himmel docs via the normal PR flow (e.g.
   [`docs/internals/environment-gotchas.md`](../internals/environment-gotchas.md),
   [`docs/operator-conventions.md`](../operator-conventions.md)) — the full
   routing table lives in the `himmel-ops:memory-compound` skill.
3. **Slim** the `MEMORY.md` index: drop the now-compounded entry, or collapse it
   to a one-line pointer (`… → vault [[note-name]]`). Keep every topic file until
   you have re-indexed and confirmed the moved content is findable, then delete it.

The ordering matters: **land the knowledge in the vault before trimming the
index**, and re-index (`qmd update` + `qmd embed`) and spot-check findability
before deleting any source file. Done in that order the move is zero-loss — the
learning is now searchable substrate, and the always-loaded index shrinks back
under budget.

This is a manual, operator-cadenced pass (run it when `MEMORY.md` approaches its
size limit), not an automatic hook — it requires judgement about what is durable
versus disposable. It is one of several capture paths, mapped next.

## What reaches the vault — automatic vs manual

A new user reading "Stage 1 — Capture (automatic)" above can assume *everything*
ends up in the vault. It does not. The automatic capture writes a session
**summary** on a graceful exit — it does **not** capture the mid-session
*findings, decisions, and learnings* themselves. Those reach the vault only when
you **explicitly invoke a capture skill**. Knowing which paths are automatic,
which are scheduled, and which are manual is the difference between a vault that
quietly compounds and one with silent gaps.

| Tier | What it captures | Entry point |
|------|------------------|-------------|
| **Automatic** | Session **summary** (decisions/commands/follow-ups) on graceful `SessionEnd` — enabled by default (HIMMEL-469) | `end-session-wiki` hook — no action required |
| **Semi-automatic** (scheduled) | Inbox clips → triaged + synthesized notes; periodic vault health | `/pipeline-cadence arm` schedules `/harvest-clips`→`/triage-clips` (daily), `/synthesize-clips`→`/archive-clips` (weekly), `/obsidian-health` (monthly). Generic `/schedule` + `/loop` drive any recurring pass. |
| **Manual** (you invoke it) | The mid-session findings/sources the automatic path misses | see list below |

**Manual capture — what you must invoke explicitly:**

- **A conversation's findings/decisions** → the vault's obsidian-second-brain
  capture skills: `/obsidian-save` (everything worth keeping from the chat),
  `/obsidian-log` (a dev/work session), `/obsidian-capture` (a quick idea). This
  is the path the "automatic" summary does **not** cover.
- **A repo / issue / PR URL** → `/luna-ingest <url>` (obsidian-triage) — fetches,
  classifies, and files a structured note under `30-Resources/Tech/`.
- **A Telegram message / URL / forward** → `/telegram-clip` files it into
  `Clippings/` for the harvest pipeline to pick up.
- **Open-web research** → the obsidian-second-brain research toolkit
  (`/research`, `/research-deep`); grounded research → `/notebooklm`.
- **Historical Claude Code sessions** (pre-vault) → `/luna-backfill`.
- **Claude Code's own auto-memory** → the distil pass in
  [the section above](#a-second-loop-auto-memory--vault).

The automatic and scheduled tiers keep the raw corpus flowing in on their own;
the manual tier is where you decide what is worth keeping — and it is the only
tier that captures the substance of a working session, not just its summary.

## What the loop gives you over time

| Volume | Benefit |
|--------|---------|
| A few sessions | Searchable log of what changed and why |
| A few weeks | Triage surfaces recurring themes and action items |
| A few months | Synthesis proposes cross-session patterns and promotions |
| Historical backfill | Fills gaps, giving synthesis a complete corpus |

The vault is most useful after several synthesis cycles — the first pass
identifies themes, subsequent passes refine and promote them into your
`30-Resources/` and `60-Maps/` areas.
