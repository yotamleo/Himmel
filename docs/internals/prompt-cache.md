# Prompt cache — the verified model, the audit, and the eval (HIMMEL-3837)

A prompt-cache claim in this repo is **not true until the eval shows it**. The
eval is `scripts/eval/cache-probe.sh` (read-only; reads session transcript
JSONL `usage` rows) and its fixture suite `scripts/eval/test-cache-probe.sh`.
This doc states the model the eval supports, the audit of every claim found in
the tree, and the exact re-run commands.

## The model (what the measurements support)

- The cached prefix is tools → system → messages. A change invalidates its own
  level and everything after it. Default TTL is 5 minutes and refreshes on each
  use; a 1-hour tier exists (write 2× base, 5-minute write 1.25×, read 0.1×).
  Official: <https://platform.claude.com/docs/en/build-with-claude/prompt-caching>.
- Preserved thinking (HIMMEL-3875; reported by the ticket from
  <https://platform.claude.com/docs/en/build-with-claude/preserved-thinking>,
  not independently verified here): on Fable 5.1, Opus 5.5, Sonnet 5.5 and
  Mythos 5.1 the API validates each thinking block's signature against the
  prefix before it; an edit to that prefix is a 400 on accounts created after 2026-08-31
  (older accounts only log it). **Edits that invalidate thinking also restart the cache**:
  editing an earlier message, changing the system prompt or tools, or clearing
  tool results. The cache-safe shape is therefore **append-only messages with a
  fixed system prompt and fixed tools** (audit row 10).
- `MEMORY.md` and `CLAUDE.md` are read at session start (and after compaction)
  and live in that session's **message history**. Editing either on disk does
  not touch a running session's already-built prompt, so it cannot invalidate
  that session's cache. Official:
  <https://code.claude.com/docs/en/memory> (load and 200-line / 25 KB cap),
  <https://code.claude.com/docs/en/context-window>. The same holds for any
  workspace file a session is not re-reading (graph.json, graphify-out/).
- The cost of an index edit is one extra cache write for each session
  **started or compacted afterwards**; its size (about 4k tokens) is an
  estimate from the index size, not measured (audit row 9).
- A session's first request reads a warm shared prefix (system + tools).
- An idle gap at or past the session's TTL re-pays the whole prefix on wake; a
  shorter gap does not. That, not "burning" anything while idle, is the cost of
  a parked leg.
- A full-prefix rewrite that coincides with an event is only evidence against
  the event once compaction and TTL expiry are ruled out — the probe does that.

## Audit of every prompt-cache claim in the tree

TRUE / FALSE / UNVERIFIED, each with the eval scenario (a fixture in
`scripts/eval/fixtures/cache-probe/<scenario>/`, asserted in
`test-cache-probe.sh`) and, where live evidence exists, the live run below.

| # | Claim (site) | Verdict | Evidence | `eval:` |
|---|---|---|---|---|
| 1 | "a mid-task MEMORY.md trim invalidates the prompt caches of every concurrent/armed session" (`memory-compound/SKILL.md` rail 6) | **FALSE** — fixed | official docs above; live run L1: 15 sessions across the 2026-09-29 01:49:04 edit, 14 kept / 1 compacted (explained) / 0 invalidated | `no-invalidation`, `real-invalidation` (the probe does flag a genuine rewrite) |
| 2 | "every graphify write invalidates Claude Code's prompt cache … full re-upload" (`.gitignore:24`) | **FALSE** — fixed (reworded as file-search/context hygiene) | live run L2: 14 sessions across the graph.json write (03:15:18), 14 kept / 0 invalidated | `no-invalidation` |
| 3 | "exiting gives the relaunch a clean prompt cache" (`arm-resume.sh` self-resume note, `hop.sh` /exit banner) | **FALSE** — fixed (the real reason, avoiding two processes on one handover, stays) | live run L3: a new session's first turn is warm in 1199 of 1210 sessions | `first-turn-warm`, `first-turn-cold` |
| 4 | "himmel has never measured its own read-ratio" (`docs/token-economy.md`) | **FALSE** (stale) — updated with the measured 98.2% | live run L3 | `first-turn-warm` |
| 5 | an idle leg re-primes cold when woken (`handover-system.md` § Operator-gated wrap; `*-next-session.md` clause) | **TRUE** — the wake re-pays the prefix; "burns" is figurative, an idle session costs nothing | live run L4: 113 of 126 gaps past the TTL rewrote, 41 of 14,659 shorter gaps did | `idle-ttl-5m`, `idle-ttl-1h`, `idle-none` |
| 6 | the statusline's per-tier cache-expiry countdown (`docs/patches/2026-05-16-cache-statusline.md`) | **TRUE** — the TTL model holds on both tiers | live run L4; fixtures put a 10-minute gap warm on 1h and cold on 5m | `idle-ttl-5m`, `idle-ttl-1h`, `idle-ttl-violated` |
| 7 | a cache-read collapse after a compaction or a long idle is not an external invalidation (the reading the probe applies) | **TRUE** — measured, not assumed | L1 classed 1 session `compacted`; fixtures | `compaction-lookalike`, `ttl-expiry`, `late-rewrite-unrelated`, `idle-compaction-lookalike` |
| 8 | "the 76.5% read-ratio / `<40%` = structural issue" figures (`token-economy.md`) | **UNVERIFIED** — one-tweet heuristics from another workspace; himmel's measured 98.2% neither confirms nor refutes the threshold | — | none (no fixture: a threshold from elsewhere) |
| 9 | "one extra cache write (~4k tokens) per session started or compacted after an index edit" (this doc, `SKILL.md` rail 6) | **UNVERIFIED** — an estimate from the index size, not a measured delta | — | none; ponytail: an estimate, upgrade path = a probe mode that diffs first-turn `cache_creation` before/after an edit (HIMMEL-3837 follow-up) |
| 10 | "edits that invalidate thinking also restart the prompt cache; append-only with fixed system and tools is the cache-safe shape" (this doc, HIMMEL-3875) | **UNVERIFIED** — reported by the ticket from the preserved-thinking docs page, not measured | — | none; ponytail: ticket-reported, upgrade path = a `scripts/eval/cache-probe.sh` scenario that edits an earlier turn / the system prompt and asserts the rewrite |
| 11 | "an account switch rewrites the full prefix of running sessions" (token-maxxing guide technique 3, HIMMEL-4422) | **UNVERIFIED** — no account switch has been measured. L5 is a weekly-bank reset on the SAME account (not a switch): 2 live sessions kept their prefix and survived the change, 0 invalidated, 0 compacted. It rules out "any bank/login-adjacent event rewrites the prefix", not the per-account claim | live run L5 | `account-switch` (the probe reads a kept pair); ponytail: needs a real switch to another account, re-run `invalidation --event <switch ISO>` over sessions live across it (HIMMEL-4422 follow-up) |

Counts: 3 TRUE, 4 FALSE (all fixed), 4 UNVERIFIED (noted, not guessed).
Unrelated caches (gh, graphify, qmd, npm, `USAGE_CACHE_TTL`,
`QMD_STALENESS_CACHE_TTL`) were ruled out: none is a prompt-cache claim.

## Live runs (2026-09-29, one project's transcripts, read-only)

| Run | Command | Result |
|---|---|---|
| L1 | `invalidation --event 1790639344` (01:49:04 CEST) | `verdict: not-invalidated kept=14 invalidated=0 compacted=1 ttl=0`, read-ratio 98.1 % over 12.3M tokens |
| L2 | `invalidation --event @<primary>/graphify-out/graph.json` | `verdict: not-invalidated kept=14 invalidated=0`, read-ratio 99.0 % |
| L3 | `first-turn` | `verdict: warm-start warm=1199 cold=11`, read-ratio 98.2 % |
| L4 | `idle-gap` | `verdict: ttl-consistent cold-expected=126 cold-rewrote=113 warm-expected=14659 warm-rewrote=41` |
| L5 | `invalidation --event 2026-10-05T16:00:00Z` (2026-10-05 weekly-bank reset at 100 %, same account, between ~15:55Z and ~16:16Z; events 15:55Z and 16:10Z give the same verdict) over the console and leg N1182 transcripts | `verdict: not-invalidated kept=2 invalidated=0 compacted=0 ttl=0`, read-ratio 98.1 %; console 317.5k to 319.5k read across a 2101 s gap, N1182 155k to 119k read with a 15.8k write (1605 s gap, still above half). Both sessions survived the change |

The probe reads only `usage` and timestamps; the runs put no transcript
content in the repo.

## Re-run

```bash
# the fixture suite (deterministic, no live data)
bash scripts/quiet-run.sh suite -- bash scripts/eval/test-cache-probe.sh

# a live check: did <event> invalidate running sessions' prompt cache?
bash scripts/eval/cache-probe.sh invalidation --event @<file whose mtime is the event> \
  ~/.claude/projects/<project-dir>/*.jsonl
bash scripts/eval/cache-probe.sh first-turn ~/.claude/projects/<project-dir>/*.jsonl
bash scripts/eval/cache-probe.sh idle-gap   ~/.claude/projects/<project-dir>/*.jsonl
```

Exit codes: `invalidation` 0 not-invalidated / 1 invalidated / 2 inconclusive;
`idle-gap` 0 ttl-consistent / 1 ttl-inconsistent / 2 inconclusive;
`first-turn` 0 warm-start / 1 cold-start / 2 no sessions; 64 usage error.

## Adding a claim's check

A new claim's check is one fixture directory
(`scripts/eval/fixtures/cache-probe/<scenario>/*.jsonl`, synthetic token counts
only) plus one `scenario <name> <verdict> <rc> <mode args>` line in
`test-cache-probe.sh`, plus a row in the table above naming it in `eval:`.
A fix to a cache claim without a named scenario is not done.

## Limits

`ponytail:` the rewrite and compaction thresholds are fixed (read < 0.5× the
previous turn, create > read, context drop > 25 %), chosen to separate the
fixtures and the 2026-09-29 measurements; upgrade path: make them flags when a
real run lands within 10 % of one. `invalidation` judges only the first
transition after the event (a prefix change shows on the next turn; a later
rewrite is unrelated). Timestamps are whole seconds. A helper call that never
reaches the transcript is invisible to the probe.

- `ponytail:` one TTL tier per session: any 1-hour write in a file sets 3600 s
  for every gap in it, inferred from `usage`, not from the request. A session
  that mixes tiers can have a 5-minute expiry read as `invalidated` (or a
  `warm` idle gap that rewrote), so the error is toward over-flagging, never
  toward hiding an invalidation; upgrade path: take the tier from the last
  write turn before each pair (HIMMEL-3837 follow-up).
- A rewrite is a read that falls below half the previous turn's with more
  created than read. A partial-prefix invalidation that keeps at least half the
  prior read (a late edit in a long history) reads as `kept`; the probe can rule
  out a full-prefix rewrite, not a partial one. A `MEMORY.md` change sits in the
  first message, so a real invalidation of it would drop the read far below half.
- `read-ratio:` is cache_read over all input tokens for every counted turn of
  every file given, in every mode; in `first-turn` it is not the first turn's
  ratio (the `warm=`/`cold=` counts are).
