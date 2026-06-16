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
3. `plan.md` contains any of the keywords: `scope`, `re-scope`, `phase 1`, `phase 2`, `phase 3`, `subsume`, `reframe`, `umbrella` (case-insensitive)
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
