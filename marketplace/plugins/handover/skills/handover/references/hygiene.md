# Hygiene — Stale Detection, Lingering, Triage, Consolidate, Analyse

## Stale tier rules

Tiers measured against UTC days since the most recent `next-session-*.md` mtime (or item dir mtime if no session files exist):

| Tier | Threshold | Action surface |
|---|---|---|
| warming | mtime > <warming>d | listed in tech-debt.md `## Warming` |
| stale | mtime > <stale>d | listed in `## Stale` + included in cold-start nudge |
| zombie | mtime > <zombie>d | listed in `## Zombie` + always in cold-start nudge top-3 |

Thresholds from `stale_thresholds_days` registry field. Defaults: 30/60/90.

**Exclusions:**
- status == `done` → never stale.
- status == `deferred` AND bucket index ∈ {3 (someday/icebox)} → never stale (it's parked on purpose).
- `pending_jira_link: true` → listed under `## Pending Jira links`, NOT in the stale tiers.

## Lingering detection (orthogonal to age)

An item is **lingering** when ALL of:

1. Type = epic
2. Status = `in-progress`
3. `plan.md` (or `master-plan.md` when `plan.md` is absent — same precedence as `update-status` tech-debt generation) contains any of the keywords: `scope`, `re-scope`, `phase 1`, `phase 2`, `phase 3`, `subsume`, `reframe`, `umbrella` (case-insensitive)
4. >= 2 session files (`next-session-*.md`) in the epic dir
5. Zero sub-tasks transitioned to `done` (or `closed`) after the latest scope-expansion session file's mtime

Lingering items appear in `tech-debt.md` `## Lingering (decompose me)` regardless of stale tier. Surface always in cold-start nudge.

## tech-debt.md format

```markdown
---
template_version: 2
---
# Tech Debt — <user> @ <repo-name>

> Auto-regenerated. UTC: <ts>
> Thresholds: warming <w>d / stale <s>d / zombie <z>d

## Lingering (decompose me)

- **<ID>** <slug> — re-scoped <date>; <K> sub-tasks closed since (need decompose)

(none if empty)

## Zombie (>=<z>d untouched)

- **<ID>** <slug> · <bucket> · mtime <date>

## Stale (<s>d to <z>d untouched)

- ...

## Warming (<w>d to <s>d untouched)

- ...

## Pending Jira links

- **#<N>** <slug> — Jira create failed <date>; run `/handover jira-link <N>` to retry

(none if empty)
```

## Hygiene command modes

`/handover hygiene [triage|consolidate|analyse]` — default = all three.

### triage

For every entry across all `tech-debt.md` sections, `AskUserQuestion` with per-item action options:

- Lingering: `[1] file phase-1 + phase-2 tasks now`, `[2] mark scope as final`, `[3] close as deferred`, `[4] skip`
- Zombie: `[1] close as done (PR was merged)`, `[2] close as dropped`, `[3] move to icebox`, `[4] re-activate`
- Stale: `[1] re-activate (reset stale clock)`, `[2] move to icebox`, `[3] close as deferred`, `[4] skip`
- Warming: `[1] re-activate`, `[2] skip` (warming is informational; no aggressive options)
- Pending Jira link: `[1] retry jira-link auto`, `[2] supply key manually`, `[3] skip`

The user can also pick `Other` to free-text input. Save-default is offered for each verdict so subsequent runs auto-apply.

### consolidate

Cross-item scan for related/overlapping items:

1. **Path overlap:** grep each `brief.md`/`master-plan.md` for top-level paths it touches. Items sharing >=2 paths are candidates.
2. **DoD overlap:** parse each item's "Definition of Done" or "Success Criteria" list; tokenize; items with >=50% token overlap are candidates.
3. **Slug similarity:** compute Levenshtein distance over slugs; items with distance <= 5 are candidates.
4. **Never-filed follow-ups:** for each closed item, grep its `next-session-*.md` for "follow-up", "filed", "TODO" referencing an ID that doesn't exist. List as "ghost follow-ups".

Output as a numbered list with suggestions:

```
Consolidation candidates (3):

[1] <ID-A> + <ID-B> — overlap on scripts/jira/. Suggest: fold <ID-B> under <ID-A>.
[2] <ID-A> + <ID-B> + <ID-C> — 70% DoD overlap. Suggest: promote to new epic.
[3] <ID-D> — ghost follow-up "<missing-id>" referenced in session-2.md but never filed.
```

User can `/handover consolidate apply <N>` to act on a suggestion.

### analyse

Corpus metrics, written to stdout:

```
Filing rate (last 30d):      4 epics + 7 standalones = 11
Close rate (last 30d):       3 epics + 5 standalones = 8
Net backlog change:          +3 items (growing)

Median sessions per closed epic:    3
P90 sessions per closed epic:       8
Median sessions per closed task:    1

Pending Jira links:          0 (healthy)
Sync.log size:               24KB (healthy; archive at 1MB)

Bucket distribution:
  now (wip):       1 (7%)
  next-up:         2 (14%)
  backlog:         9 (64%)
  icebox:          2 (14%)

Most-edited reviewer-notes.md (last 30d):
  1. <ID> <slug>  — 4 feedback entries
  2. <ID> <slug>  — 1 feedback entry
```

## Command flow — `/handover hygiene [mode]`

Maintenance command. `<mode>` is `triage`, `consolidate`, `analyse`, or omitted (= all three). Load `references/resolution.md` for Target Repo Resolution.

0. **Resolve target repo.** When triage will apply a verdict — `close` / `move bucket` / `re-activate` are frontmatter mutations — enter the target repo's **Worktree Gate** first (`references/resolution.md`), never on `main`. The read-only `consolidate` / `analyse` scans need no gate.
1. **Read** `<state-root>/tech-debt.md` (already up-to-date from latest `update-status`).
2. Execute the requested mode(s) per the "Hygiene command modes" section above:
   - **triage** — iterate over every entry in tech-debt.md; `AskUserQuestion` per item with per-tier action options.
   - **consolidate** — run path-overlap, DoD-overlap, slug-similarity, and ghost-follow-up scans; print numbered suggestions.
   - **analyse** — compute corpus metrics; print summary.
3. **Apply** triage verdicts as soon as the user answers (skill executes the chosen action: close, move bucket, re-activate, etc.). Once verdicts are applied, **run `update-status`** to regenerate `status.md` / `roadmap.md` / `tech-debt.md` — triage changes item state, so the auto-files are stale until regenerated.
4. **Apply** consolidate suggestions only on `/handover consolidate apply <N>` follow-up (this command does NOT auto-act on consolidate).
5. **Print** analyse output to stdout (no side effects).
6. **Append** a single hygiene entry to `sync.log`.

Save-defaults supported: triage verdicts can opt-in to "always close zombie as deferred", "always re-activate stale", etc. via `defaults["hygiene.zombie_default"]`, `defaults["hygiene.stale_default"]`, etc. — keys documented in the triage section above and `references/init-register.md`.

## Command flow — `/handover consolidate apply <N>`

Act on a consolidation suggestion from the last `/handover hygiene` (or `/handover hygiene consolidate`) run. `<N>` is the suggestion number.

`consolidate apply` is a **mutation** — it moves directories, rewrites refs, and transitions Jira. Treat it as such: it runs inside the **Worktree Gate** (`references/resolution.md`), never on `main`, and each apply is written to be re-runnable so a mid-flow failure can be resumed rather than leaving refs / dirs / Jira half-changed.

The skill must remember the most-recent consolidate output. Store it transiently in `<state-root>/.last-consolidate.json` (gitignored) with the list of suggestions. On `apply <N>`:

0. **Resolve target repo → Worktree Gate.** Enter the target repo's worktree before any mutation.
1. Read `<state-root>/.last-consolidate.json` (reference it by its full `<state-root>` path — it lives at the state root, NOT inside the worktree entered in step 0, so a bare relative read from the worktree cwd would miss it); locate suggestion N.
2. **Preflight — validate before mutating** (retry-aware, compatible with the step-3 re-runnable skips). For each referenced item, accept EITHER of two valid states: (a) the source dir still exists at its recorded path, or (b) the move already completed on an earlier run — the source is **absent** AND the expected destination already holds the **same** `<ID>-<slug>` item (identity match). Treat (b) as VALID and let step 3's re-runnable skips carry the retry forward; do NOT reject it as stale. Confirm every Jira key still resolves. **Stop and report** only for genuinely bad states: a source is missing with **no** identity-matched destination (the stored suggestion is stale — re-run `/handover hygiene consolidate`), or the expected destination is occupied by an **unrelated** item (a real directory collision). Do not begin a partial apply on a genuinely stale suggestion.
3. Execute its proposed action. Do each sub-step so it is **individually re-runnable** — but a re-run must never mask a real conflict:
   - **Skip a move only on an identity match.** Skip a `git mv` when the destination already exists **and** holds the expected source item (same `<ID>-<slug>`). If the destination exists but holds an **unrelated** item (a directory collision), **stop and report** — never treat an unrelated collision as a completed move.
   - **Rewrite references idempotently.** Match and rewrite only the **old** path (old → new); a ref already pointing at the new path is left untouched. A second pass over already-updated links must be a no-op — never double-rewrite (e.g. never turn an already-rewritten `Y/tasks/X` into `Y/tasks/Y/tasks/X`) or otherwise corrupt links, so re-running the rewrite after a partial run is safe.
   - Skip a Jira transition already in the target state.
   - **Persist and reuse a created epic ID.** When "promote A+B+C to new epic" creates the epic, record its Jira key in `<state-root>/.last-consolidate.json` immediately; on a retry after partial failure, **reuse** that recorded key instead of creating a second epic.

   Sub-steps:
   - "fold X under Y" → `git mv` dir X under Y/tasks/ (identity-checked skip above); rewrite refs; transition X's Jira to a Task under Y's Epic.
   - "promote A+B+C to new epic" → `AskUserQuestion` for new epic name; create epic (reuse the persisted key on retry); move A/B/C as tasks under it.
   - "ghost follow-up X referenced but never filed" → `AskUserQuestion`: "file as standalone now?"
   On any sub-step failure, **stop and report exactly which sub-steps completed** (do not silently continue past a failed move/transition); the operator re-runs `apply <N>` and the idempotent skips carry it forward from where it stopped.
4. Run `update-status`.
5. Append to `sync.log` (trigger=consolidate-apply).
