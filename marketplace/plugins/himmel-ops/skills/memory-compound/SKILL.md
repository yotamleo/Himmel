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
   **All landings go on a BRANCH in a worktree — vault AND repo** (operator
   directive 2026-07-14): himmel docs through the normal worktree → PR flow,
   and vault notes via a vault worktree on a `chore/memory-compound-<date>`
   branch (`git -C <vault> worktree add <path-outside-vault> -b <branch>`),
   committed + pushed, and merged by the OPERATOR after review. The vault is
   a single-writer personal repo with no PR gate by design (the
   `.single-writer` convention in root `CLAUDE.md`) — the branch + operator
   merge IS its review step; himmel-side landings keep the full PR + approval
   flow. Never write the live vault checkout or main directly — the branch is
   about trackability and reviewable merges, not parallelism.
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
- **Remote stations** (D5, HIMMEL-570). Memory is per-host: a fact captured on
  another machine never loads here. Read the station registry — the luna note
  `[[himmel-remote-stations]]` — and **skip cleanly if it is absent** (adopters
  have no remote stations; this is not an error). For each listed host, inventory
  its store over ssh and record index bytes + topic-file count/names. An
  **unreachable / timed-out / auth-failed host is a WARN that does NOT silently
  pass** — a silently skipped host *is* the multi-host bug recurring. Fold any
  remote durable item through the same propagation review + qmd gate below;
  delete the remote topic file only after its landed line is qmd-findable. Keep
  station specifics (hostnames, shells) in the registry note, not here — memory
  and the vault do not propagate to other users, so the skill text stays
  adopter-generic.

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
  **When in doubt, land in himmel docs** (operator directive 2026-07-14):
  luna is not shared, so an adopter-relevant item that lands only in luna is
  silently dropped for every other user. Gotchas about himmel-SHIPPED tooling
  (`/luna-upgrade`, `propagate-public.sh`, `/pr-check` profiles, dispatch
  chokepoints, …) are adopter-relevant even when discovered on the operator's
  own vault — land them in the repo (`docs/` or the owning plugin's README).
- **Rule / restriction candidates.** An adopter-generic item that is
  frame-shaping or safety-critical deserves more than a doc: run it through
  the HIMMEL-177 layer test (default-hook / default-rule / lean-invoke /
  defer) and FILE A TICKET for the promotion (CLAUDE.md line, PreToolUse
  hook, pre-commit gate) — doc it now, ticket the escalation. (HIMMEL-195:
  prose that already drifted escalates to structural, not to more prose.)

Match each note's existing voice and structure. One writer, many readers.

**Triage by SHAPE before landing (D9, HIMMEL-570).** Orthogonal to the
propagation class above — decide *where recall happens*:

- **Fact-shaped** — looked up on a symptom ("rtk masks gitleaks blocks"). →
  evict to its theme topic file; the `MEMORY.md` line becomes a routing line
  (step 5).
- **Directive-shaped** — must fire *unprompted*; the model never queries for a
  rule it does not know it is breaking ("NEVER merge with open CR comments"). →
  **keep it resident** as a ≤200-char `MEMORY.md` line, **or** file a HIMMEL-195
  escalation for a structural hook. A directive behind a qmd query is dead.
- **Invocation-shaped** — fires only inside a named flow (a `/pr-check` gotcha, a
  codex-dispatch trap, a jira-CLI quirk). → land it in the **existing skill /
  command / script that owns that flow** (adopter-generic → the repo-tracked
  skill body, gated by the propagation review above; operator-private → a
  user-scope skill or a resident line). Do **not** mint a per-theme memory skill
  (rejected — ~516B/skill of always-loaded catalog re-creates the index-bloat
  problem in a worse surface).

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

**Scope the gate to the curated collection (D8, HIMMEL-570).** The
`luna-curated` collection is ~351 docs (the `30-Resources/Tech/**` scope that
holds the ~17 theme notes the index routes to); an **unscoped** memory query
instead searches the full `luna` collection's ~13,253 docs — a **~38:1**
dilution (13,253 : 351) that sank the 2026-07-16 recall probes.
Query `-c luna-curated` **first** (the `30-Resources/Tech/**` scope; keep it
fresh with `qmd_cmd update -c luna-curated`), full `luna` only as a fallback on
a miss. **⚠ The flag is `-c` / `--collection` (singular) — `--collections`
(plural) is NOT a qmd flag and is SILENTLY IGNORED**, so a gate run with
`--collections luna-curated` searches *everything* while looking scoped and
"confirms" a false pass. Set `minScore: 0.5` and an `intent`.

**Branch caveat (BOTH collections):** qmd indexes the PRIMARY checkouts, not
worktrees — a doc landed on a himmel PR branch AND a vault note landed on a
vault branch are not qmd-findable until their branches merge. For everything
landed on a branch (which, per rail 1, is everything), the gate splits:
verify the content sits in the pushed branch/PR now; run the re-index +
findability spot-check AFTER the merges land in the primary checkouts, and
only then delete the source topic files. Steps 5–6 of a fully-branched pass
therefore run as a short POST-MERGE follow-up, not in the landing session.

### 5. Slim `MEMORY.md`
Back it up first (a single `.bak`, removed in step 6 once the next session loads
cleanly — it is a transient safety copy, not a kept history). **Abort the slim if
the backup did not write** — same land-before-trim discipline: never edit the
index without a recoverable copy:

```bash
cp "$MEMDIR/MEMORY.md" "$MEMDIR/MEMORY.md.bak" || { echo "backup failed — aborting slim"; exit 1; }
```

Then, in the index — matching the shipped post-migration format (`- [Title](topic.md) — <keyword hooks>` for facts; a bare `- <directive>` line for directives):
- **Drop** pure-status entries outright.
- **Fact-shaped** entry → collapse to a **routing line ≤200 chars**:
  `- [Title](topic.md) — <keyword hooks>`. **KEEP the `[Title](topic.md)`
  link** — it is the native route to the tier-2 topic file the D7 read-protocol
  reads first (root `CLAUDE.md`: "read the theme topic file its keyword names").
  The hooks are a short comma-list of symptom keywords, **not** inlined bodies —
  bodies live in the topic file, never in the index line.
  **If the keyword-hook list would push the line past 200 chars, SPLIT the
  theme** — carve the overflowing domain into its OWN topic file + routing line;
  do NOT drop keywords and do NOT chain ~24 gotchas onto one fat line. This binds
  compound's OWN output: the 2026-07-16 pass emitted a 1,472-char line — that
  line *is* the store, which `context-architecture.md` forbids.
- **Fact-shaped, graduated to an adopter himmel doc** (its topic file is deleted
  in step 6) → `- <keyword hooks> → docs/internals/<doc>.md`. Use a **bare
  repo-relative path, NOT `[…](topic.md)` link form** — the step-6 dangling-link
  scanner greps `](…md)`, so a bare path is (correctly) ignored, and there is no
  local topic file for it to point at.
- **Directive-shaped** entry → a resident bare `- <directive> …` line ≤200 chars
  (no topic-file link; it must fire unprompted — see the shape triage in step 3).
- **Compound is NOT exempt from `guard-memory-capture.sh`** (HIMMEL-1088) and
  must **not** be launched with its bypass (`MEMORY_CAPTURE_OK=1`) set — that
  would reduce it to prose-governed, the layer this design rejects. `*.bak` is
  exempt by scope. If a legitimate multi-host fold exceeds the 400B growth cap
  in one write, use the narrow waiver (growth cap relaxed only when *every* line
  passes the 200-char rule), never a blanket bypass.

The goal is an index back under budget where every routing line is ≤200 chars
and resolves to where the fact lives: a kept, trimmed topic file (the common,
deterministic recall path), or — for an adopter-graduated fact — the himmel doc
that now carries it. Durable content is additionally graduated to luna/himmel
for durability + reach.

### 6. Trim topic files; delete only when fully graduated (after the gate)

**Graduate, do NOT delete a fact you can only recall by symptom (spike
HIMMEL-1086).** The 2026-07-17 spike measured symptom-shaped qmd recall at
**4/10** even inside the scoped `luna-curated` collection, while reading the
theme topic file the routing line names is **3/3 deterministic**. So the topic
file is the primary (tier-2) recall path, and folding a fact to luna is a
tier-3 durability/propagation copy — **not** a reason to delete its topic file.
Delete a topic file **only** when its content is reachable *without* a symptom
qmd query: it graduated to an **adopter-generic himmel doc** (qmd-findable in
the `himmel` collection *and* path-addressable), or its fact is fully carried by
a **resident** directive line. For a fact whose only home is a `luna` note,
**keep a trimmed topic file** (routing line + the distilled body) rather than
deleting it. (The full fold-and-trim semantics + the inverted orphan-topic-file
audit ride **HIMMEL-1090**; this guard is the safe floor until then.)

For each remaining topic file whose durable content is **confirmed findable**
(step 4), whose index entry is now a pointer (step 5), AND which has **fully
graduated to an adopter-generic himmel doc or resident directive** per the guard
above, delete it:

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

Any `DANGLING:` line means a topic file was deleted (fully graduated) but its
index entry still links it — rewrite that entry to point at where the fact now
lives: `- <hook> → docs/internals/<doc>.md` for an adopter-graduated fact (a bare
repo-relative path, **not** in `[…](…)` link form, so this scanner ignores it),
or fold it into a resident directive line (drop the dead `[…](file.md)` link),
then re-run the scan. No clean scan → the pass is not done.

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
