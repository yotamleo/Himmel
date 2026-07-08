# Lesson provenance schema v1 (HIMMEL-767)

himmel's self-evolving loop (lessons → tickets / draft PRs) is
garbage-in/garbage-out without trustable capture. This schema gives every
**lesson record** — one claim worth acting on later — a pointer back to the
evidence that would confirm or refute it, so a later audit can sample and
verify precision before any lesson feeds automation.

This doc defines the schema and what the validator
(`scripts/lessons/validate-lesson.mjs`) rejects. The sample-audit gate
(deliverable 2, `scripts/lessons/sample-audit.mjs` —
[`docs/internals/lesson-audit.md`](lesson-audit.md)) and the write-fence
(deliverable 3) are separate, later PRs.

## Two serializations, same fields

- **Frontmatter form** — for `.md` lesson artifacts (e.g. auto-memory topic
  files, dedicated lesson notes): a `lesson:` block nested inside the file's
  existing YAML frontmatter. Additive — nothing existing moves.
- **JSONL form** — for machine-written streams (session-end capture,
  daily-ingest, a per-vault `lessons.jsonl` ledger): one JSON object per line,
  the record's fields at the top level (no `lesson:` wrapper).

### Frontmatter example

```yaml
---
type: reference
lesson:
  id: 2026-07-08-example-widget-api-429
  claim: "Widget API returns 429 under concurrent writes; serialize calls."
  source:
    type: session
    ref: "transcripts/session-42.jsonl:120-160"
  captured_at: 2026-07-08T14:32:00Z
  captured_by: manual
  confidence: high
  scope:
    - harness
  status: active
---
```

### JSONL example

```json
{"id":"2026-07-08-example-widget-api-429","claim":"Widget API returns 429 under concurrent writes; serialize calls.","source":{"type":"session","ref":"transcripts/session-42.jsonl:120-160"},"captured_at":"2026-07-08T14:32:00Z","captured_by":"end-session-wiki","confidence":"high","scope":["harness"],"status":"active"}
```

## Field table

| Field | Req | Semantics |
|---|---|---|
| `id` | yes | `YYYY-MM-DD-<kebab-slug>`; stable forever; supersession links point at it |
| `claim` | yes | The lesson itself, 1–3 lines, self-contained (no "see above") |
| `source.type` | yes | `session` \| `cr` \| `incident` \| `operator` \| `compound` |
| `source.ref` | yes | Evidence pointer: transcript path + line-range, PR number, ticket key, or (for `compound`) the source lesson `id`s / memory files distilled from |
| `captured_at` | yes | ISO-8601 UTC |
| `captured_by` | yes | Writer identity: `end-session-wiki` \| `memory-compound` \| `daily-ingest` \| `manual` \| `auto-memory` |
| `confidence` | yes | `high` (observed directly / reproduced / operator-stated) \| `medium` (inferred from one occurrence) \| `low` (speculative). Writer-assessed; the audit re-scores |
| `scope` | yes | ≥1 tag from the controlled list: `guardrails`, `cr`, `lanes`, `jira`, `handover`, `telegram`, `vault`, `env-windows`, `env-macos`, `billing`, `harness`. Extensible — add a tag here **and** to `SCOPE_TAGS` in `scripts/lessons/validate-lesson.mjs`, kept in lockstep |
| `status` | yes | `active` \| `superseded` \| `invalidated` \| `unverified` (writer default: `unverified` for `low`/`medium` confidence, `active` for `high`) |
| `supersedes` | no | Prior lesson `id` this replaces; the writer flips that record's `status` to `superseded` + sets its `superseded_by` |
| `superseded_by` | no | Reverse link, set on the superseded record |
| `audit` | no | Written **only** by the deliverable-2 sample-audit (`scripts/lessons/sample-audit.mjs` — [`docs/internals/lesson-audit.md`](lesson-audit.md)): `{audited_at, verdict: confirmed\|refuted\|stale, auditor}`. The capture path never writes this block |

## Binding rules

1. **Additive, never migratory.** Existing memory files / session notes are
   not backfilled — the schema applies only to lessons captured after a
   writer wires in. Old prose has no recoverable evidence, which is exactly
   the failure this schema exists to prevent.
2. **Evidence or it isn't a lesson.** Every record must carry a `source.ref`
   evidence pointer — the validator enforces presence and shape; *resolving*
   the pointer (does the evidence actually exist and support the claim?) is
   the deliverable-2 audit's job. "I remember this" →
   `source.type: operator` with the conversation/session ref.
3. **Supersession is the only edit.** A wrong lesson is never rewritten in
   place; a new record supersedes it, keeping the audit trail honest.
4. **The `audit` block is single-writer.** Only the deliverable-2 sample-audit
   writes it — the capture path must never emit `audit`. The validator has two
   modes for this: writers validate with `--capture` (strict capture-time —
   ANY `audit` block fails), while the deliverable-2 auditor and any at-rest
   sweep validate without the flag (at-rest — an `audit` block passes iff
   well-formed: `audited_at` ISO-8601, `verdict` in
   `confirmed|refuted|stale`, `auditor` non-empty).

## What the validator rejects

`scripts/lessons/validate-lesson.mjs` fails a record when:

- Any required field (table above) is missing or empty.
- `id` doesn't match `YYYY-MM-DD-<kebab-slug>`.
- `source.type`, `confidence`, `status`, or `captured_by` isn't one of its
  enum values.
- `scope` is empty, not a list, or carries a tag outside the controlled list.
- `captured_at` doesn't parse as ISO-8601 UTC.
- `audit` is present at all, in `--capture` mode (rule 4 — capture-time).
- `audit` is present but malformed, in default (at-rest) mode: missing or
  non-ISO-8601 `audited_at`, `verdict` outside `confirmed|refuted|stale`,
  or missing `auditor` (rule 4 — at-rest).

For `.md` files the validator checks **both carriers**: the `lesson:`
frontmatter block and any body `## Lessons` section containing a fenced
`jsonl` block (the session-note form). A `.md` file with **neither** is not
an error — it passes as "not a lesson" (not every memory file is a lesson).
A `lesson:` key that is present but not a mapping, a lesson block using
tab indentation, or a `## Lessons` heading whose fenced `jsonl` block is
missing, mislabeled, or unclosed fails with a named rule rather than
passing silently.
Within one JSONL input, duplicate `id`s fail (the ledger is append-only;
ids are the audit's addressing keys).

## Wiring in

Writers validate before they finalize a lesson write — always with
`--capture` (capture-time mode; rule 4 above):

```bash
node scripts/lessons/validate-lesson.mjs --capture path/to/note.md
node scripts/lessons/validate-lesson.mjs --capture path/to/lessons.jsonl
some-writer | node scripts/lessons/validate-lesson.mjs --capture -   # stdin JSONL
```

The deliverable-2 auditor and at-rest sweeps run the same validator
*without* `--capture` (a well-formed `audit` block then passes).

Exit code is `1` if any record is invalid, `0` otherwise (including the
"not a lesson" case). Lean-invoke, not a hook (HIMMEL-177) — it rides the
writers that already run at session end / compound time:

- **auto-memory topic files** — a topic file that records a lesson
  (feedback/reference gotcha) should include the `lesson:` frontmatter block
  (files without it remain valid memory but are excluded from the
  self-evolving pipeline). Guidance lives in the `memory-compound` skill.
- **memory-compound** — when landing a durable learning into a theme note,
  carries provenance forward: the landed line gets a trailing `^lesson:<id>`
  anchor, and the skill writes the full JSONL record to the per-vault
  `lessons.jsonl` ledger (`source.type: compound`).
- **end-session-wiki** — the LLM crystallization pass may append an optional
  `## Lessons` section (JSONL-form records, `source.ref` = the note's own
  path + `#Lessons`, `captured_by: end-session-wiki`). Fail-open: a broken
  lesson block never blocks session capture.

## Non-goals (v1)

No embedding/retrieval layer (qmd already indexes the artifacts), no
automatic staleness detection, no backfill of pre-schema prose, no new
always-on hooks.
