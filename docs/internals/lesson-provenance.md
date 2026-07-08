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

## Write-fence (deliverable 3)

The self-evolving loop this schema feeds is **propose-only**: a lesson can
only reach code as a ticket or a draft-PR body, through the existing CR +
operator-merge gate. It is never allowed to edit enforcement surfaces
directly. That posture is now backed by a structural fence, not just
convention: `scripts/guardrails/lesson-write-fence.sh` denies the loop
enforcement-path writes on the agent file-tool surface
(Edit/Write/MultiEdit/NotebookEdit) — that classifier is unchanged and
exhaustive (it always has the exact `file_path` in hand) — and on the
Bash/PowerShell `command` surface, which as of **round 4** uses an
inverted model instead of enumerating write-shaped verbs.

**Round 4: deny-list → allow-list inversion.** Rounds 1–3b each closed one
more per-verb write-shape gap on a deny-list of known writers — glued
redirects, attached `-t` flags, PowerShell built-in aliases — and each
round's adversarial CR found a *new* gap the same way (`ln -sf`,
`truncate`, `mkdir`, ...): enumerating "every way to write a file" is an
open set, so a deny-list on that set converges slowly if at all. Round 4
inverts the rule: a small closed set of command-position verbs **proven to
only read** (`cat`/`grep`/`ls`/`diff`/`wc`/`sed` without `-i`/`find`
without `-delete`/`-exec`/`git` read-verbs/interpreters running a
script/PowerShell readers like `Get-Content`/`Select-String`/...) is
exempt from operand checking; **every other verb — known writer, unknown
mutator, or a tool this fence has never heard of — has every operand
scanned as a write-target candidate.** `ln`, `truncate`, `mkdir`, and any
future write verb are covered for free, because the rule is "not proven
safe" rather than "known unsafe". Two mechanisms sit outside the verb
check entirely, since they can write regardless of which verb is exempt:
redirect targets (`>`/`>>`/glued forms/`dd`'s `of=`) always deny, and the
git hook-routing shape-deny (below) always runs. One deliberate behavior
change from the inversion: the old `cp`-source read carve-out is gone —
`cp` is not proven read-only, so ALL its operands (including the source)
are candidates now; `cat`/`grep` remain the way to inspect an enforcement
file without cp-ing it out.

Full per-clause model: (1) every token is checked for a redirect operator
*anywhere inside it* (not just a leading position — the word-splitter here,
like graphify-fence's, only splits on whitespace, so `echo
x>scripts/hooks/a.sh` arrives as ONE token and the target must be extracted
from inside it), and any redirect target that classifies as enforcement
denies unconditionally; (2) the command-position verb is resolved after
skipping leading `VAR=val` assignments and the wrappers `command`/`exec`/
`builtin`/`nohup`/`time`/`nice`/`env`/`sudo`/`timeout` (chainable, adapted
from graphify-fence.sh's wrapper walk); (3) if that verb is on the
proven-read-only allow-list, the clause is allowed outright; (4) otherwise
every non-redirect operand is a candidate — a plain token as-is (bare
words too, no `is_path_like` gate, unchanged from round 2), a dash-prefixed
token via its inline value only (`-Path:X`/`-Path=X`/
`--target-directory=X`, plus the `cp`/`install` glued short flag `-tDIR`
with no separator at all), with `-Value`/`-Value:x`/`-Value=x` (any case)
skipped everywhere — that parameter name conventionally holds literal
content being written, not a target (round-3b's fix, now applied
uniformly instead of to three named cmdlets). PowerShell's free-form
argument order (e.g. `Copy-Item`'s source) is covered by the same uniform
scan without a PowerShell-specific dispatch, because a value token's own
shape (dash or not), not which flag preceded it, decides whether it is
classified.

Plus, unchanged since round 3b, a hook-routing git-config shape-deny
covering `core.hooksPath` (`git config core.hooksPath`, `git config
--unset core.hooksPath`, `git -c core.hooksPath=...`) and `include.path`/
`includeif.*` (same three forms — an included config file can itself set
`core.hooksPath`); every token in that scan is stripped of one layer of
surrounding quotes before matching, so a quoted key (`git -c
'core.hooksPath=X' commit`, `git config "core.hooksPath" X`) is caught too.
This check runs unconditionally per clause, independent of the verb
allow-list, so a routing key still denies even under an otherwise
read-shaped git invocation.

**Round 5 (this round) closed four finite gaps in the round-4 model, no
architecture change.** (1) The interpreters (`node`/`python`/`python3`/
`bash`/`sh`/`pwsh`/`bun`/`deno`) are no longer *unconditional* allow-list
members: they are exempt only when executing a script FILE (no inline-eval
flag). An inline-eval flag — node/bun/deno `-e`/`--eval`, python `-c`,
bash/sh `-c`, pwsh `-Command`/`-c`/`-EncodedCommand` — makes the
interpreter NOT exempt, and the clause's raw text (not the split token
array, since the write target lives inside a quoted argument) is scanned
for any enforcement-path signal from the loaded policy; a hit denies
(`python -c "open('scripts/hooks/x.sh','w')..."`, `node -e
"fs.writeFileSync('scripts/guardrails/x.sh',...)"`), no hit allows
(`python -c "print(1)"`). (2) The git hook-routing shape-deny now resolves
its git-clause head through the same wrapper-skipping walk
(`_clause_head_idx`) the general classifier uses, instead of checking only
the clause's first token — closing `command git -c core.hooksPath=X
commit`, `env git config --add include.path X`, `sudo git ...`, and
`timeout N git ...`. (3) The redirect-target scan's standalone fd-prefixed
form (`N>`/`N>>`) now accepts any number of digits, not just one — `10>
scripts/hooks/a.sh` classifies its target correctly (the single-digit-only
glob char class previously dropped the target on a 2+-digit fd). (4) The
leading `VAR=val` assignment skip accepts any letter-case
(`[A-Za-z_][A-Za-z0-9_]*=`), not just lowercase, so `FOO=1 cat
scripts/hooks/a.sh` and `BAR=2 BAZ=3 grep x scripts/guardrails/lib.sh`
resolve their verb correctly instead of risking a false over-deny.

**Round 6 closed a clause-split bypass in the redirect scan.** `>|`
(noclobber-override write) and `>&` (redirect both streams to a FILE) each
contain one of the `;`/`|`/`&` metacharacters `evaluate_command` splits
clauses on — splitting BEFORE recognizing these two-character operators
stranded the `>` at the end of the first clause (no target) and turned the
redirect's TARGET into the second clause's HEAD, a position the operand
scanner never inspects (`echo x >| scripts/hooks/a.sh` and `echo x >&
scripts/hooks/a.sh` both allowed). The fix normalizes `>|` and `>&` to a
plain `> ` before the clause split, so the target stays attached to a `>`
in the same clause and is classified by the existing redirect scan. Real
fd-dups (`2>&1`, `>&2`) are unaffected — they normalize to `2> 1` / `> 2`,
whose targets (`1`/`2`) are non-enforcement and still allow.

**Round 7 closed a process-substitution gap.** `>(...)`/`<(...)` with a
proven-read-only OUTER verb previously slipped past the whole model:
`echo x > >(tee scripts/hooks/a.sh)` and `cat foo > >(tee
scripts/hooks/a.sh)` both allowed, because the outer verb (`echo`/`cat`)
hit the round-4 read-only short-circuit and returned allow before the
inner `tee` — a real write, once bash actually runs the substitution — was
ever examined; the redirect scan only classifies the token immediately
after `>`/`<`, which is the procsub opener itself (`>(tee`), not the writer
buried inside it. The fix reuses round 5's coarse
`_clause_has_enforcement_signal` substring scan: if any token in the
clause carries a bare `>(` or `<(`, the clause's raw text is scanned for an
enforcement-path signal and denies on a hit — unconditionally, before the
verb is even resolved, so no outer-verb exemption (read-only allow-list or
interpreter) can short-circuit past it. No hit allows
(`echo x > >(tee /tmp/ok.txt)`). Process substitution is now a **covered
shape** (coarse substring gate), not an unlisted gap — same residual as
round 5's inline-eval check: a target path built by STRING CONCATENATION
inside the procsub never appears as one literal substring and is not
caught. A clause carrying an INPUT procsub of an enforcement path (`diff
<(cat scripts/guardrails/lib.sh) ...`) also denies under this same coarse
scan even though that procsub only reads — an accepted safe-direction
over-block, consistent with the fence's existing `<` treatment.

Honestly stated: this is not everything — `git apply`/`patch` (target
lives in the diff body, not a command token), a target built by STRING
CONCATENATION inside an interpreter's inline-eval string or a process
substitution (never appears as one literal substring, so the coarse scan
misses it — a narrower residual than before round 5, not a closed one),
`find ... -exec`/`xargs`'s deferred command arguments (materialised at
runtime, not statically detectable), a handful of allow-listed readers'
own rarely-used write flags (`sort -o FILE`, GNU `awk -i inplace`), `<`
input-redirection denying like `>` even though nothing is written (this
fence cannot tell redirect direction apart any more reliably than it tells
shell dialects apart), and wrapper/quoting displacement via an
unrecognized wrapper or a user-defined shell alias/function (the small set
above — `env`/`sudo`/`timeout`/`exec`/... — is handled, now including
ahead of a git clause for hook-routing detection too; an unlisted or
user-defined wrapper is not) are accepted out-of-charter gaps (documented
in the fence's own header). Those shapes are exactly what the
CR/operator-merge primary gate exists to catch — this fence is
**defense-in-depth under that gate, not a replacement for it**: a bad
lesson can never disable the gate that would catch it, because the gate
itself sits outside the fence's write path.

The deny-list — `scripts/guardrails/enforcement-paths.json`, the source of
truth (14 entries: 9 prefix, 5 basename) — groups into these classes:

- **`guardrails`** — `scripts/guardrails/`: a lesson must not weaken the
  fences that would catch it.
- **`hooks`** — `scripts/hooks/`, `.codex/`, and any `hooks.json` basename
  at any depth: PreToolUse/SessionStart/Stop enforcement (both the
  plugin-delivered and the codex-lane adapter wiring) plus their tests.
- **`self-gate`** — `scripts/lessons/`: the loop must not edit its own
  provenance validator or sample-audit admission gate.
- **`settings`** — `.claude/settings.json` / `.claude/settings.local.json`:
  permission allow-rules and hook wiring are operator-only.
- **`pre-commit`** — `.pre-commit-config.yaml` and `.gitleaks.toml`: the
  pre-commit/commit-msg/pre-push gate source of truth, and the secret-scan
  ruleset it consumes.
- **`routing`** — `scripts/backends.json`: the block-backend-tier registry.
- **`parity-guard`** — `parity_guard.py` / `glm-guard.ts` basenames: the
  hermes file-tool fence and its shared guard primitive, reached wherever
  they live (including the hermes checkout).
- **`claude-md`** — `CLAUDE.md` / `AGENTS.md` basenames, root and every
  subtree: frame-shaping rules and their generated Codex/hermes mirror.

**The dispatcher contract.** Any future lessons→code dispatcher MUST export
`HIMMEL_LESSON_LOOP=1` for every worker it spawns, on **both** lanes: Claude
workers via the himmel-ops plugin hook wiring, and codex workers via
`.codex/hooks.json`. A worker spawned without that marker is not
fence-covered — the fence is inert by design when the marker is absent
(zero always-on cost, HIMMEL-177) — and must never be given lessons→code
work. A dispatcher can pre-flight a proposed change-set in CLI mode before
ever spawning a worker:

```bash
bash scripts/guardrails/lesson-write-fence.sh check <path>...
```

This prints one `deny\t<class>\t<path>` or `allow\t-\t<path>` line per
path and exits 2 if at least one path denies, 0 if all allow.

**Delivery note.** The Claude-lane half of this fence ships via the
himmel-ops plugin `hooks.json` (`scripts/hooks/block-lesson-enforcement-writes.sh`),
the same delivery path as `block-docker-privesc`/`block-merged-pr-commit`
(HIMMEL-441/512): it is live only after `/himmel-update` (marketplace
re-sync) + a fresh session, not immediately on merge.
