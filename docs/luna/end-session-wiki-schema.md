# End-Session Wiki — Session Note Schema

Defines the structure of every session note auto-filed into the Luna Obsidian vault by the epic #7 `SessionEnd` hook. Schema is the founding convention for the `sessions/` tree (no prior notes exist there as of 2026-05-18).

**Status:** shipped — the `SessionEnd` hook writes these notes live; see [`end-session-wiki.md`](end-session-wiki.md) for the operational controls (opt-out, dry-run, repo-config).

**Cross-references:**
- Epic context: HIMMEL-18 end-session-wiki-hook (tracked in the operator's private handover repo)
- Task brief: HIMMEL-79 session-note-schema (tracked in the operator's private handover repo)
- `SessionEnd` payload contract: HIMMEL-78 stop-hook-spike spike-results (origin/spike/end-session-stop-hook; tracked in the operator's private handover repo)
- Luna vault operating manual: `<luna>/`_CLAUDE.md` (AI-First Vault Rule §0)

**See also:** [`end-session-wiki.md`](./end-session-wiki.md) — operational controls (opt-out env var, repo-local config, dry-run mode, logs).

---

## 1. Path Convention

```
sessions/YYYY/MM/YYYY-MM-DD-HHMM-<slug>.md
```

All times are **UTC**, derived from the `SessionEnd` event timestamp.

| Segment | Source | Example |
|---------|--------|---------|
| `YYYY/MM/` | Year + zero-padded month of session end (UTC) | `2026/05/` |
| `YYYY-MM-DD` | ISO date of session end (UTC) | `2026-05-18` |
| `HHMM` | 24h hour + minute of session end (UTC), zero-padded | `1432` |
| `<slug>` | See slug derivation below | `himmel-feat-end-session-wiki-schema` |

### Slug derivation rule

```
slug = slugify("{repo}-{branch}")
```

1. `repo` = git remote `origin` basename without `.git`, fallback to last segment of `cwd`.
2. `branch` = `git -C <cwd> branch --show-current`, fallback to `detached`.
3. Concatenate `repo` + `-` + `branch`.
4. Slugify: lowercase, replace any run of non-`[a-z0-9]` chars with `-`, strip leading/trailing `-`.
5. **Max length = 80 chars.** If longer, truncate at the last `-` boundary that fits within 80, else hard-truncate at 80.
6. **Reserve room for collision suffix.** The 80-char cap is the budget for slug + any future `-N` collision suffix (see [Path collision rule](#path-collision-rule)). If a collision forces appending `-N` and the resulting `slug-N` would exceed 80 chars, re-truncate the slug at its last `-` boundary BEFORE appending the suffix so that `len(slug) + len("-N") ≤ 80`. If no `-` boundary fits, hard-truncate the slug to `80 - len("-N")` chars, then append the suffix.

Examples:
- `repo=himmel`, `branch=feat/end-session-wiki-schema` → `himmel-feat-end-session-wiki-schema`
- `repo=luna`, `branch=main` → `luna-main`
- worktree branch like `worktree-agent-af47e58229f29c811` slugifies as-is.

### Path collision rule

If the canonical path already exists (two sessions ending in the same UTC minute on the same branch — rare but possible with parallel worktrees), append `-2`, `-3`, … to the filename **before** the `.md` extension:

```
2026-05-18-1432-himmel-feat-foo.md          # first
2026-05-18-1432-himmel-feat-foo-2.md        # second
2026-05-18-1432-himmel-feat-foo-3.md        # third
```

The hook MUST never overwrite an existing session note.

---

## 2. Frontmatter (YAML)

Every session note begins with a YAML frontmatter block. Field order below is canonical — the hook writes fields in this order for grep-ability.

```yaml
---
date: 2026-05-18T14:32:00Z
type: session
repo: himmel
branch: feat/end-session-wiki-schema
worktree: C:\Users\<user>\Documents\github\himmel\.claude\worktrees\agent-af47e58229f29c811
epic: "#7"
task: "#25"
duration_minutes: 47
files_touched: 2
tags:
  - session
  - autocapture
ai-first: true
session_id: <uuid from SessionEnd payload>
source: live
crystallized: false
crystallized_at:
---
```

### Field reference

| Field | Type | Required | Source | Missing-value policy |
|-------|------|:--------:|--------|---------------------|
| `date` | string (ISO 8601 UTC, `YYYY-MM-DDTHH:MM:SSZ`) | yes | `SessionEnd` event time, converted to UTC | n/a — always present |
| `type` | literal `session` | yes | constant | n/a |
| `repo` | string | yes | `git remote get-url origin` basename, fallback `path.basename(cwd)` | n/a — fallback ensures a value |
| `branch` | string | yes | `git -C $cwd branch --show-current`, fallback `"detached"` | n/a — fallback ensures a value |
| `worktree` | string (absolute path) | yes | `cwd` from `SessionEnd` payload | n/a — always present in payload |
| `epic` | string (`"#N"` form, quoted to dodge YAML comment rules) | optional | parsed from branch name `(feat\|fix\|chore)(-epic)?-N` OR from the handover repo's `<USER_SLUG>/<repo>/epics/<KEY-or-#N>-*` active marker | **OMIT FIELD** entirely when not derivable |
| `task` | string (`"#N"` form) | optional | parsed from branch / commit-msg trailer / latest `next-session-*.md` | **OMIT FIELD** entirely when not derivable |
| `duration_minutes` | integer | yes | `(SessionEnd time) - (first transcript event time)`, rounded to nearest minute | If transcript unreadable: write `0` (sentinel) |
| `files_touched` | integer | yes | `git -C $cwd diff --name-only HEAD@{session-start}..HEAD \| wc -l` — count only | If git unreadable: write `0` |
| `tags` | list of strings | yes | always includes `session` and `autocapture`; may append `epic-N`, `task-N` when those are known | n/a — defaults guarantee non-empty list |
| `ai-first` | boolean | yes | constant `true` (Luna vault AI-First Vault Rule §0) | n/a |
| `session_id` | string | yes | `session_id` from `SessionEnd` payload | Write empty string `""` if absent in payload |
| `source` | string | yes | `"live"` for hook captures; `"claude-backfill"` for backfill tool writes | n/a — always set by the writer |
| `crystallized` | boolean | yes | `false` on the mechanical render; flipped to `true` once an LLM crystallization pass has rewritten the body sections | n/a — defaults to `false` |
| `crystallized_at` | string (ISO 8601 UTC) or empty | yes | empty on the mechanical render; set to the crystallization time when `crystallized: true` | empty string when not crystallized |

**Backfill rules:** when `source=claude-backfill`, set `branch=""` (empty, branch at capture time is unknown), `files_touched=0` (no diff available), `session_id` from the transcript filename or a derived identifier.

**Crystallization fields:** every note is first written *mechanically* (`crystallized: false`, `crystallized_at:` empty). A best-effort background LLM pass — the **crystallizer** — may then rewrite the four body sections (Summary / Decisions / Files Touched / Follow-ups), preserving all other frontmatter and setting `crystallized: true` + `crystallized_at`. A note that stays `crystallized: false` is the valid mechanical baseline, not a failure. Operational detail (config, recursion guards, the husk-skip gate, and `--reheal` recovery): [`end-session-wiki.md` → Crystallization](./end-session-wiki.md#crystallization-llm-upgrade).

**Optional-field convention:** for `epic` and `task`, **omit the key entirely** rather than emitting `null`, `""`, or `~`. Rationale: Obsidian Dataview and frontmatter consumers treat absent keys consistently (`is undefined`), and absent keys keep notes scannable. Empty-string would falsely match prefix searches; `null` clutters the YAML.

---

## 3. Body Structure

After the frontmatter, every session note has exactly these six h2 sections, in this order: `## Summary`, `## Decisions`, `## Files Touched`, `## Commands`, `## Follow-ups`, `## Raw Conversation`. (The for-future-Claude preamble in 3.1 sits above the first h2 and is not itself an h2.) Empty sections are written with a single-line `_None._` placeholder rather than omitted, so the shape is predictable for future-Claude.

An optional seventh section, `## Lessons` (§3.6a), may appear between `## Follow-ups` and `## Raw Conversation` — it is **crystallizer-only** (HIMMEL-767): the mechanical render never emits it, and it is present only when the LLM synthesis pass identified a genuine reusable lesson.

### 3.1 For-future-Claude preamble (above first h2)

A 2-3 sentence summary written immediately after the frontmatter, before the first `## Summary` heading. Required by Luna AI-First Vault Rule §0 ("Every note begins with a 2-3 sentence summary so Claude can decide relevance in 10 seconds"). Distinct from `## Summary` below — this is the elevator pitch; `## Summary` is the detail.

### 3.2 `## Summary`

2-4 sentences describing what was done and why. Generated from the last assistant turn's reported outcome, or from a brief LLM summarization of the transcript (deferred to #26 implementation).

**Confidence markers** (per Luna `_CLAUDE.md` §0.7): mark non-stated claims with an inline marker — `(stated)`, `(high)`, `(medium)`, or `(speculation)`. Anything quoted directly from the session transcript defaults to `(stated)` and the marker MAY be omitted. Inferred claims (e.g. summarization output, root-cause guesses, "we will probably need X") MUST carry a marker.

### 3.3 `## Decisions`

Bullet list — each line one decision made during the session. Filter to genuinely irreversible or load-bearing choices; do not log trivial tool selections.

**Wikilinks** (per Luna `_CLAUDE.md` §0.6): link entity references — people, projects, repos, epics, tasks, concepts, tools — as `[[entity-name]]`. Bare names without links must be justified inline (acceptable bare values include one-shot identifiers like SHA hashes, env-var names, file paths, or branch names). Use the exact existing Luna page name when one exists; if not, the wikilink itself doubles as a stub-creation hint for the vault.

**Confidence markers** (per Luna `_CLAUDE.md` §0.7): same convention as §3.2 — mark inferences with `(stated | high | medium | speculation)`; decisions explicitly made in the session default to `(stated)` and the marker may be omitted.

```markdown
## Decisions

- Chose `SessionEnd` over `Stop` for [[end-session-wiki-hook]] because Stop fires per-turn (spike-results.md §2).
- Omitted optional epic/task fields instead of null to keep frontmatter scannable. (high)
- Bound schema to [[himmel]] convention, mirroring [[Luna]] `_CLAUDE.md` §0.
```

If no decisions: `_None._`.

### 3.4 `## Files Touched`

Bullet list of repo-relative paths from `git diff --name-only` over the session window.

- **Cap at 50 entries.** If more than 50, list the first 50 and append a final line: `- _+N more (use git log to inspect)_` where `N = total - 50`.
- Order = `git diff --name-only` output order (alphabetical).
- Each entry is wrapped in backticks for path safety: `` - `path/to/file.ext` ``.

If no files: `_None._`.

### 3.5 `## Commands`

Fenced ` ```bash ` block listing the last N notable shell commands executed during the session (where N is bounded by the transcript size — recommend N=20 unless the section grows past ~40 lines).

**Filter rule** — drop trivial commands:
- `ls`, `cd`, `pwd`, `echo` (with any args) — pure navigation/inspection.
- Commands that produced no observable side effect (exitCode=0 AND no stdout AND no file change).

**Keep:** anything that mutated state (git, npm, pytest, file edits via CLI, gh, etc.) and any command with a non-zero exit code (for failure archaeology).

```markdown
## Commands

```bash
git fetch origin spike/end-session-stop-hook
git -C <worktree> commit -m "feat(epic-7): #25 session-note schema + canonical example"
gh pr create --title "feat(epic-7): #25 session-note schema"
```
```

If no commands: empty bash fence (` ```bash\n``` `).

### 3.6 `## Follow-ups`

Bullet list of TODOs surfaced during the session — explicit deferrals, "next session should X" notes, reviewer questions, etc. Source: parse the transcript for phrases like "follow-up", "next session", "TODO", or explicit follow-ups the assistant flagged.

**Wikilinks** (per Luna `_CLAUDE.md` §0.6): same convention as §3.3 — link entity references (people, projects, repos, epics, tasks, concepts) as `[[entity-name]]`. A follow-up that names an epic, task, or repo without a wikilink should be treated as a lint warning.

**Confidence markers** (per Luna `_CLAUDE.md` §0.7): optional here — most follow-ups are explicit deferrals (effectively `(stated)`). Mark speculative or "may need to" items with `(speculation)` so future-Claude knows they are not commitments.

If none: `_None._`.

### 3.6a `## Lessons` (optional, crystallizer-only, HIMMEL-767)

Present only when the LLM crystallization pass (see
[`end-session-wiki.md` → Crystallization](./end-session-wiki.md#crystallization-llm-upgrade))
judged the session surfaced a genuine reusable lesson — a gotcha, decision, or
fact worth remembering beyond this session, not routine status. The
mechanical render never emits this section; a note that stays
`crystallized: false` never has one either.

Body: a fenced ` ```jsonl ` code block, one JSON object per line, each
matching the lesson-record schema in
[`docs/internals/lesson-provenance.md`](../internals/lesson-provenance.md):
`source.type: session`, `source.ref` = this note's own vault-relative path +
`#Lessons`, `captured_by: end-session-wiki`.

````markdown
## Lessons

```jsonl
{"id":"2026-07-08-example-widget-api-429","claim":"Widget API returns 429 under concurrent writes; serialize calls.","source":{"type":"session","ref":"sessions/2026/07/2026-07-08-1432-himmel-feat-foo.md#Lessons"},"captured_at":"2026-07-08T14:32:00Z","captured_by":"end-session-wiki","confidence":"high","scope":["harness"],"status":"active"}
```
````

Fail-open: a malformed line here must never block session capture — the
crystallizer's existing best-effort semantics cover it (see
[Crystallization](./end-session-wiki.md#crystallization-llm-upgrade)). A
record's actual validity is checked later, out of band, by
`node scripts/lessons/validate-lesson.mjs --capture` (lean-invoke, not at
capture time; `--capture` because these are capture-path records — any
`audit` block fails).

### 3.7 `## Raw Conversation`

Obsidian collapsible callout wrapping the last assistant turn (or last few turns) verbatim. Kept for forensic value when the auto-generated `## Summary` proves wrong months later. Collapsed by default so the page stays scannable.

```markdown
## Raw Conversation

> [!note]- Raw conversation
> <last assistant turn text here, with each line prefixed by `> `>
> Multi-line content stays inside the callout because every line starts with `>`.
```

If the transcript was unreadable, write:

```markdown
> [!note]- Raw conversation
> _Transcript unavailable._
```

---

## 4. Canonical Example

A real session note built from the live session that authored this schema lives at:

```
<luna>/sessions/2026/05/2026-05-18-1432-himmel-feat-end-session-wiki-schema.md
```

This example is the source of truth for any formatting ambiguity — if the spec and example disagree, treat the example as the bug and fix the example.

---

## 5. Mirroring Luna conventions

This schema honors the Luna `_CLAUDE.md` AI-First Vault Rule:

| Rule | How session-note schema satisfies it |
|------|---------------------------------------|
| §0.1 Self-contained context | Frontmatter carries repo/branch/worktree — note explains itself with no surrounding context |
| §0.2 "For future Claude" preamble | Mandatory 2-3 sentence block between frontmatter and `## Summary` |
| §0.3 Rich consistent frontmatter | `type: session`, `date`, `tags`, `ai-first: true` all present |
| §0.4 Recency markers per claim | `date` field + the note is dated by name; individual claims in body should still attach dates |
| §0.5 Sources preserved verbatim | `## Raw Conversation` callout preserves the assistant turn unedited |
| §0.6 Cross-links mandatory | `## Decisions` and `## Follow-ups` should use `[[wikilinks]]` to people/projects/concepts when applicable |
| §0.7 Confidence levels | Body claims should mark `stated | high | medium | speculation` per Luna rule |

No prior `sessions/` notes existed before this schema — this is the founding convention.
