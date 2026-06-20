# Luna Compounding Loop

Your vault compounds value automatically — each stage in the pipeline
transforms raw session output into structured knowledge, and that knowledge
feeds the next stage. This document describes the loop, what each stage
adds, the recommended cadence, and how to seed the vault with historical
sessions.

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
