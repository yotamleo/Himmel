# Lesson sample-audit — precision gate (HIMMEL-767 deliverable 2)

## Why

Lesson provenance records (`docs/internals/lesson-provenance.md`) are only
trustworthy as automation input if they're actually true. Before any
lessons → tickets / draft-PR pipeline consumes them, a human (or model)
auditor samples a slice of the ledger, resolves each record's evidence
pointer, and verdicts it. The gate is binary: **≥90% confirmed, or the
self-evolving loop stays off.** This is the tool that runs that sample →
verdict → apply → gate cycle: `scripts/lessons/sample-audit.mjs`.

## When to run

- Before enabling any consumption of lesson records by automation
  (tickets, draft PRs, prompts).
- Periodically thereafter — lessons drift stale as the world changes, and
  new lessons accumulate that were never audited.

## The flow

### 1. Collect target artifacts

Point the tool at the lesson-bearing files: per-vault `lessons.jsonl`
ledgers (written by `memory-compound`), auto-memory topic files carrying a
`lesson:` frontmatter block, and session notes with a body `## Lessons`
section (written by `end-session-wiki`). Any mix of `.md` and `.jsonl`
files works — `sample` extracts from all three carriers in one pass.

### 2. Sample

```bash
node scripts/lessons/sample-audit.mjs sample \
  path/to/lessons.jsonl path/to/*.md \
  --n 20 --seed 1 --out worksheet.jsonl
```

- Extracts every lesson record from the given files (frontmatter `lesson:`
  blocks, body `## Lessons` fenced-jsonl blocks, and plain `.jsonl` lines).
- Keeps only records with `status: active` or `status: unverified` —
  `superseded`/`invalidated` records are already resolved, nothing to audit.
- Excludes records that already carry an `audit` block, by default (pass
  `--include-audited` to re-audit — e.g. a periodic re-check of a `stale`
  verdict, or a spot-check of prior audit quality).
- Sorts the eligible population by `id` (tie-broken by origin file path)
  for determinism, then takes a seeded pseudorandom sample of size `--n`
  (default 20, `--seed` default 1 — same inputs + same seed = same sample,
  every time).
- If the eligible population is smaller than `--n`, `sample` exits **3**
  (the ≥90% gate needs ≥20 samples to mean anything). `--allow-small`
  (paired with `--n`) lifts this for tests/smoke runs only — never use it
  to force a real gate run through on too little data.
- Output is worksheet JSONL: one line per sampled record, the full record
  plus `"origin": {"file", "carrier"}`, `"verdict": ""`, `"notes": ""`.

### 3. Resolve + judge each record

For every worksheet line, follow `source.ref` back to the evidence and
decide:

- **confirmed** — the evidence exists and supports the claim as stated.
- **refuted** — the evidence is missing, contradicts the claim, or doesn't
  support the claim's stated strength (e.g. `confidence: high` for
  something that was actually a one-off guess).
- **stale** — the claim was true and supported when captured, but the
  world has changed since (an API got fixed, a tool got replaced). Also
  re-score the writer's `confidence` in `notes` if it was off.

Fill in `"verdict"` (one of `confirmed|refuted|stale`) and optionally
`"notes"` on each worksheet line directly — hand-edit the JSONL, or script
it. Auditor identity is either a model name (`claude-sonnet-5`,
`claude-opus-4.8`) or `"operator"` for a human pass — set it per-line via a
`"auditor"` field, or once for the whole run via `--auditor`.

### 4. Apply

```bash
node scripts/lessons/sample-audit.mjs apply \
  --verdicts worksheet.jsonl --auditor claude-sonnet-5
```

- Refuses (exit 1) if any line is unverdicted, has an invalid verdict, is
  missing an auditor, or names an id that no longer exists at its origin
  (the artifact moved/changed since sampling).
- Writes the audit block back to the **origin artifact only** —
  frontmatter carrier gets a nested `audit:` mapping inside the existing
  `lesson:` block; jsonl/body-lessons carriers get their exact line
  rewritten with an added `"audit"` key. Every other line in the file is
  untouched, byte-for-byte.
- Stage-then-commit: the new content for **all** touched files is built
  and validated with the at-rest validator
  (`validateMarkdown`/`validateJsonlText`, no `--capture`) **in memory
  first** — a validation failure, including pre-existing unrelated
  corruption elsewhere in a touched file, aborts before any disk write.
  Only then are files written, each atomically (temp file + rename in the
  same directory) with a post-write read-back re-validation as a belt.
- Atomicity in the write phase is per-file, not transactional across the
  run: if a write still fails mid-loop (filesystem error), that file is
  restored, an explicit accounting is printed (`applied` / `restored` /
  `not-attempted` files), and the tool exits 1 — files written before the
  failing one keep their audit blocks. Re-running `apply` after fixing
  the cause is safe: already-audited ids still resolve in the preflight
  and are simply re-written. When re-running after a partial failure,
  pin `--audited-at` to the same timestamp so the retried records match
  the already-applied ones. `audit` stays single-writer: this is the only
  path that ever writes it (rule 4, `docs/internals/lesson-provenance.md`).

### 5. Gate

```bash
node scripts/lessons/sample-audit.mjs gate --verdicts worksheet.jsonl
```

- Requires every worksheet line to carry a valid verdict and the total to
  be ≥20 (`--allow-small` for tests/smoke only) — otherwise exits 3.
- Prints per-verdict counts and `precision = confirmed / total` to 4
  decimal places.
- Exits 0 iff `precision >= threshold` (`--threshold`, default `0.90`),
  else 1. Wire this exit code into whatever gate the lessons → automation
  pipeline checks before it's allowed to run.

## Outcome handling

**Refuted and stale lessons are never edited in place** — supersession is
the only edit (binding rule 3, `docs/internals/lesson-provenance.md`).
Write a new record with `supersedes: <old id>`, flip the old record's
`status` to `superseded` and set its `superseded_by`, following whatever
writer produced the original (`memory-compound`, `end-session-wiki`,
manual). The audit block on the superseded record stays as the historical
record of why it was retired.

## Example run, start to finish

```bash
node scripts/lessons/sample-audit.mjs sample \
  ~/luna/lessons.jsonl ~/luna/30-Themes/*.md \
  --n 20 --seed 1 --out worksheet.jsonl

# ... resolve source.ref for each line, fill verdict + notes ...

node scripts/lessons/sample-audit.mjs apply \
  --verdicts worksheet.jsonl --auditor operator

node scripts/lessons/sample-audit.mjs gate --verdicts worksheet.jsonl
echo "gate exit: $?"
```
