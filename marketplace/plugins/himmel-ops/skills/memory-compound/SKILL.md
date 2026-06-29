---
name: memory-compound
description: Use when the per-project auto-memory store (`~/.claude/projects/<project-slug>/memory/`: the always-loaded `MEMORY.md` index + one topic file per fact) is approaching or over its load budget (~24.4KB) — the harness emits a size-limit warning at session load when over budget (e.g. "MEMORY.md is NN KB (limit 24.4KB)"), content past the limit is silently dropped = partial recall. Losslessly compounds the DURABLE gotchas out of the auto-memory into qmd-searchable luna / himmel reference notes (read-many → write-once → qmd gate → slim index → delete sources), so the always-loaded index stays lean. Lean-invoke, operator-run on demand — NOT an always-on hook (HIMMEL-569).
---

# memory-compound — distil auto-memory into searchable substrate (HIMMEL-569)

Lean-invoke skill. Run it when `MEMORY.md` approaches its load budget (~24.4KB)
— the session-load size-limit warning (e.g. "MEMORY.md is NN KB (limit 24.4KB)")
is the natural cue. It encodes the HIMMEL-564 compaction as ONE pass. Do **not**
wire this as an
always-on hook — the classification (durable vs disposable), dedupe, and
placement are judgement-heavy, which is exactly why HIMMEL-177 puts it at the
lean-invoke layer.

The documented move it automates: [`docs/luna/compounding.md` §"A second loop:
auto-memory → vault"](../../../../../docs/luna/compounding.md#a-second-loop-auto-memory--vault).

## Safety rails — read first

These are non-negotiable. The pass is zero-loss **only** if you keep this order.

1. **Read-many, write-once (single-writer rule).** Fan out reader subagents
   **READ-ONLY** to mine the topic files in parallel. Exactly ONE writer (you,
   the parent) appends synthesized content to the vault. Never fan parallel
   writes at a shared note. (Single-writer rule: HIMMEL-166 / root `CLAUDE.md`.)
2. **Land before you trim.** Append the durable learning to its vault note
   BEFORE you touch `MEMORY.md`, and trim `MEMORY.md` BEFORE deleting any topic
   file.
3. **qmd gate before any deletion.** Re-index (`qmd update` + `qmd embed`) and
   spot-check that the moved content is findable. Delete a topic file **only**
   after its content is confirmed searchable in the vault. No gate pass → no
   deletion.
4. **Back up `MEMORY.md` first.** Copy it aside before the first edit so the
   index is recoverable if the pass is interrupted.
5. **Status is disposable, not durable.** PR numbers, "merged", ticket state,
   dates → drop them (already recoverable from Jira, git history, and the
   `sessions/` captures). Only the reusable gotcha / decision compounds.

## Resolve the memory dir (step 0)

The auto-memory lives at `~/.claude/projects/<project-slug>/memory/`. The
`MEMORY.md` already injected into THIS session is the authoritative target —
do not guess a different store. Locate the directory:

```bash
ls -1 ~/.claude/projects/*/memory/MEMORY.md
```

If more than one matches, pick the store whose `MEMORY.md` matches the index
loaded in this session (same entries). Export it for the steps below:

```bash
MEMDIR="$HOME/.claude/projects/<project-slug>/memory"
```

Confirm the budget before doing work — if it is comfortably under ~24.4KB there
may be nothing to compound:

```bash
wc -c "$MEMDIR/MEMORY.md"
ls -1 "$MEMDIR"/*.md | wc -l
```

## Runbook

### 1. Inventory
Read `$MEMDIR/MEMORY.md` and list the topic files (`$MEMDIR/*.md`, excluding
`MEMORY.md`). Each topic file is one fact with frontmatter (`type:` =
`user|feedback|project|reference`). Group the files by theme — environment
traps, harness gotchas, operator conventions, project status, … — so each
reader gets a coherent batch.

### 2. Mine (READ-ONLY fan-out)
Dispatch one **read-only** reader subagent per theme group. Each reads its
topic files and returns, per file, a structured verdict:

- **durable gotcha / decision** — the reusable learning, distilled to 1–3
  lines, plus the theme it belongs to and any `[[wikilinks]]` it already
  carries. (Compoundable.)
- **pure status** — ephemeral (PR/ticket/date/"merged"). (Droppable, no
  synthesis.)
- **mixed** — durable core + status chrome; return only the durable core.

Readers do not write anything. The parent owns synthesis across all of them.

### 3. Land (single-writer synthesis)
You (the one writer) append each durable learning to the matching reference
note, **deduping against existing curated content** — extend or sharpen an
existing line rather than appending a near-duplicate:

- **Operator-specific / vault-shaped** → the luna vault under
  `30-Resources/Tech/` (or the theme note already used by the memory index's
  luna pointers — many entries already name a `[[luna note]]`). Grouped by
  theme: environment traps, harness gotchas, operator conventions, …. Resolve
  the luna vault from `$LUNA_VAULT_PATH` (configured via `/end-session-wiki-setup`),
  falling back to the operator's known luna path; **confirm the directory exists
  before writing** and never hardcode a home dir — a wrong/unset path would
  scatter the synthesized notes outside the vault and silently fail the qmd gate.
- **Adopter-generic** (true for anyone running himmel, no personal state) →
  himmel `docs/internals/` (e.g. `environment-gotchas.md`, `enforcement.md`).

Match each note's existing voice and structure. One writer, many readers.

### 4. qmd gate — THE GATE
Re-index the vault and confirm findability **before** any deletion. Run from the
himmel repo root (the `source` path is repo-root-relative):

```bash
source scripts/lib/qmd-bin.sh
qmd_cmd update
qmd_cmd embed
```

Then spot-check that each landed learning is retrievable — query the collection
you wrote to (`luna` for vault notes, `himmel` for `docs/internals/`) for a
phrase unique to the moved content and confirm it returns the new note. Use the
qmd MCP `query` tool, or `qmd_cmd query`. A learning that does not surface is
**not** compounded — fix the note (or its frontmatter) and re-index before
proceeding. No findability → no deletion.

### 5. Slim `MEMORY.md`
Back it up first (a single `.bak`, removed in step 6 once the next session loads
cleanly — it is a transient safety copy, not a kept history). **Abort the slim if
the backup did not write** — same land-before-trim discipline: never edit the
index without a recoverable copy:

```bash
cp "$MEMDIR/MEMORY.md" "$MEMDIR/MEMORY.md.bak" || { echo "backup failed — aborting slim"; exit 1; }
```

Then, in the index:
- **Drop** pure-status entries outright.
- **Collapse** each compounded entry to a one-line pointer:
  `- [Title](file.md) — hook → luna [[note-name]]` becomes a pointer with no
  surviving topic file, i.e. a bare `- <hook> → luna [[note-name]]` line (or
  `→ himmel docs/internals/<doc>.md`). Keep the searchable hook; drop the body.

The goal is an index back under budget where every dropped body is now
qmd-findable substrate.

### 6. Delete compounded topic files (only after the gate)
For each topic file whose durable content is **confirmed findable** (step 4) and
whose index entry is now a pointer (step 5), delete it:

```bash
rm "$MEMDIR/<compounded-topic>.md"
```

Leave any file you could not confidently compound (ambiguous, still-active
project state) in place — partial progress is fine and safe. Keep
`MEMORY.md.bak` until the operator confirms the next session loads cleanly under
budget, then it can be removed.

## When you are BUILDING this skill vs RUNNING it

This SKILL.md *defines* the compaction. When you are developing the skill (not
running a real compaction), do **not** delete or rewrite any real `MEMORY.md`
topic file — you are shipping the runbook, not executing it.

## Optional: monthly safety-net nudge

The over-budget load warning is the primary trigger. As a backstop you can have
the OS scheduler NUDGE monthly (a reminder to consider running `/memory-compound`)
— it must **nudge, never auto-run**, since the pass needs judgement. The generic
`/schedule` and `/loop` drivers can carry such a reminder; do not arm an
unattended auto-compaction.

## Reference

- Documented pass: [`docs/luna/compounding.md`](../../../../../docs/luna/compounding.md#a-second-loop-auto-memory--vault).
- Worked precedent: HIMMEL-564 (the by-hand 56KB → 16KB compaction this automates).
- Layer choice (lean-invoke, not a hook): HIMMEL-177; single-writer rule: HIMMEL-166.
