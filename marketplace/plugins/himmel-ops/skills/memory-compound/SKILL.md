---
name: memory-compound
description: Use when the per-project auto-memory store (`~/.claude/projects/<project-slug>/memory/`: the always-loaded `MEMORY.md` index + one topic file per fact) is approaching or over its load budget (~24.4KB) — the harness emits a size-limit warning at session load when over budget (e.g. "MEMORY.md is NN KB (limit 24.4KB)"), content past the limit is silently dropped = partial recall. Losslessly compounds the DURABLE gotchas out of the auto-memory into qmd-searchable luna / himmel reference notes (read-many → propagation review → write-once → qmd gate → slim index → delete sources), so the always-loaded index stays lean and adopter-generic learnings land in himmel docs (memory + vault never propagate to other users). Lean-invoke, operator-run on demand — NOT an always-on hook (HIMMEL-569).
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
6. **Run in a DEDICATED session.** `MEMORY.md` loads into every session, so a
   mid-task trim invalidates the prompt caches of every concurrent/armed
   session, and a hurried inline trim loses recall hooks. When the size
   warning fires mid-task: note it, finish the task, run `/memory-compound`
   in its own session. (Adding a genuinely NEW entry mid-task stays fine.)
7. **Memory does not propagate — adopter-generic learnings MUST land in
   himmel docs.** Auto-memory and the luna vault are operator-side only; a
   generic gotcha compounded only into luna is invisible to every other
   himmel user. The propagation review in step 3 is a gate, not a suggestion.

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

Also inventory, in the same pass:

- **Stale backups** — `ls -1 "$MEMDIR"/*.bak 2>/dev/null`. A `MEMORY.md.bak`
  left by a PRIOR completed pass is delete-eligible once the current index
  loads cleanly. If a `.bak` diverges from everything mined (entries today's
  index and topic files no longer carry), diff it and recover the missing
  durable items through the same pipeline before deleting it.
- **Orphaned sibling stores** — `ls -d ~/.claude/projects/*/memory/`. Stores
  under project slugs whose root was renamed or deprecated (a renamed vault
  dir, a deprecated state repo) never load in any session; their durable
  facts are stranded. Mine them through this same pass (or fold the few live
  facts into the current store), then delete the orphaned store.

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
  lines, plus the theme it belongs to, any `[[wikilinks]]` it already
  carries, and its **propagation class** — operator-specific vs
  adopter-generic (the step-3 review makes the final call). (Compoundable.)
- **pure status** — ephemeral (PR/ticket/date/"merged"). (Droppable, no
  synthesis.)
- **mixed** — durable core + status chrome; return only the durable core.

Readers do not write anything. The parent owns synthesis across all of them.

### 3. Propagation review + Land (single-writer synthesis)
You (the one writer) append each durable learning to the matching reference
note, **deduping against existing curated content** — extend or sharpen an
existing line rather than appending a near-duplicate.

**The propagation review is mandatory, per item, BEFORE writing.** Auto-memory
and the luna vault never reach another himmel user; anything true for other
users must land in the repo or it is lost to them. Defaulting everything to
luna is the documented failure mode — the 2026-07-11 pass did exactly that and
needed a follow-up PR (HIMMEL-900). Classify each durable item:

- **Operator-specific / vault-shaped** (this operator's machines, lane
  inventory, personal vaults, quota habits, personal workflow) → the luna
  vault under `30-Resources/Tech/` (or the theme note already used by the
  memory index's luna pointers — many entries already name a `[[luna note]]`).
  Resolve the luna vault from `$LUNA_VAULT_PATH` (configured via
  `/end-session-wiki-setup`), falling back to the operator's known luna path;
  **confirm the directory exists before writing** and never hardcode a home
  dir — a wrong/unset path would scatter the synthesized notes outside the
  vault and silently fail the qmd gate.
- **Adopter-generic** (true for anyone running himmel — OS/shell/tool traps,
  git behaviours, Claude Code quirks, dev-workflow conventions worth
  standardizing) → **himmel docs, via the normal worktree → PR flow** (himmel
  is PR-gated; the vault is not). Route by content: environment/OS/tool traps
  → `docs/internals/environment-gotchas.md`; operator working-habits →
  `docs/operator-conventions.md`; other-harness compat →
  `docs/internals/harness-compat.md`; hook/gate lore →
  `docs/internals/enforcement.md`. Batch all of the pass's doc landings into
  ONE docs PR at the end. A luna copy is optional; the himmel doc is the
  system of record for these.
- **Rule / restriction candidates.** An adopter-generic item that is
  frame-shaping or safety-critical deserves more than a doc: run it through
  the HIMMEL-177 layer test (default-hook / default-rule / lean-invoke /
  defer) and FILE A TICKET for the promotion (CLAUDE.md line, PreToolUse
  hook, pre-commit gate) — doc it now, ticket the escalation. (HIMMEL-195:
  prose that already drifted escalates to structural, not to more prose.)

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

**Adopter-generic caveat:** the `himmel` collection indexes the PRIMARY
checkout, not worktrees — a doc landed on a PR branch is not qmd-findable
until the PR merges. For those items the gate splits: verify the content sits
in the pushed PR now, and delete the source topic file only AFTER the docs PR
merges and a re-index finds the learning in the `himmel` collection.

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
- **Collapse** each compounded entry to a one-line pointer. The topic file is
  being deleted in step 6, so the `[Title](file.md)` markdown link MUST be
  dropped — a surviving `[…](file.md)` would dangle at a file that no longer
  exists. Rewrite `- [Title](file.md) — hook → luna [[note-name]]` to a **bare**
  `- <hook> → luna [[note-name]]` line (or `→ himmel docs/internals/<doc>.md`):
  no `[…](file.md)` link, keep the searchable hook + the `→ luna [[note]]`
  pointer, drop the body.

The goal is an index back under budget where every dropped body is now
qmd-findable substrate.

### 6. Delete compounded topic files (only after the gate)
For each topic file whose durable content is **confirmed findable** (step 4) and
whose index entry is now a pointer (step 5), delete it:

```bash
rm "$MEMDIR/<compounded-topic>.md"
```

**Post-slim gate — no dangling links.** Same discipline as the step-4 qmd gate:
a check, not a hope. After the deletions, every `[Title](file.md)` link in
`MEMORY.md` must point at a file that still exists — a link to a just-deleted
topic file is exactly the drift this guard catches (HIMMEL-641). Scan the index
for any `](…md)` whose target is now missing:

```bash
grep -oE '\]\(([^)]+\.md)\)' "$MEMDIR/MEMORY.md" | sed -E 's/^\]\(//; s/\)$//' | while read -r link; do
  [ -e "$MEMDIR/$link" ] || echo "DANGLING: $link"
done
```

Any `DANGLING:` line means a step-5 collapse was missed — go back and rewrite
that entry to a bare `- <hook> → luna [[note]]` pointer (drop the dead
`[…](file.md)` link), then re-run the scan. No clean scan → the pass is not done.

Leave any file you could not confidently compound (ambiguous, still-active
project state) in place — partial progress is fine and safe. Adopter-generic
items whose docs PR has not merged yet also stay (topic file or collapsed
pointer line) until the post-merge `himmel`-collection re-index finds them
(step 4 caveat). Keep
`MEMORY.md.bak` until the operator confirms the next session loads cleanly under
budget, then it can be removed.

## Lesson provenance carry (HIMMEL-767)

When a mined memory qualifies as a **lesson** (a feedback/reference gotcha,
not pure status), carry its provenance forward instead of laundering it away
— this is the piece that stops compounding from losing the evidence trail.
Schema: [`docs/internals/lesson-provenance.md`](../../../../../docs/internals/lesson-provenance.md).

- **Source topic files.** A topic file that records a lesson should include
  the `lesson:` YAML frontmatter block (files without it remain valid memory
  but are excluded from the self-evolving pipeline — the pipeline consumes
  only schema-carrying records).
- **Landing (step 3, above).** When you append the durable learning to its
  theme note, give the landed line a trailing `^lesson:<id>` anchor (mint a
  fresh `YYYY-MM-DD-<kebab-slug>` id if the source topic file carried none),
  then write the full record (JSONL) to that vault's `lessons.jsonl` ledger
  (one append-only file at the vault root) with `source.type: compound`,
  `source.ref` = the list of source memory topic-file paths distilled from,
  and `captured_by: memory-compound`.
- **Validate before delete.** Before step 6 deletes any source topic file,
  run `node scripts/lessons/validate-lesson.mjs --capture <vault>/lessons.jsonl`
  (from the himmel repo root; `--capture` = capture-time mode — any `audit`
  block fails, since the capture path never writes one) and confirm the new
  record(s) PASS. This rides alongside the qmd gate (step 4), not instead of
  it — no PASS, no deletion.

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
- Lesson provenance schema + validator: [`docs/internals/lesson-provenance.md`](../../../../../docs/internals/lesson-provenance.md) (HIMMEL-767).
- Layer choice (lean-invoke, not a hook): HIMMEL-177; single-writer rule: HIMMEL-166.
