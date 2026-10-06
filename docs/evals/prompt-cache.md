# Eval case study: prompt cache and the harness runner (HIMMEL-4550)

What himmel measures about the prompt cache, how, and what the numbers say.
Everything here was re-run on 2026-10-06 at commit `321346770`; the table is
that run, not a copy of an older one. The audit of each cache claim and the
fixture-by-claim map stay in
[`docs/internals/prompt-cache.md`](../internals/prompt-cache.md); this page is
the method, results and re-run command.

## Method

A prompt-cache claim counts only once a probe shows it. The probe is
`scripts/eval/cache-probe.sh`. It is read-only: it reads the `usage` rows
(`input`, `cache_read`, `cache_creation`) and timestamps from Claude Code
session transcripts (JSONL), and prints a deterministic report and a verdict
exit code. It makes **no model call**, so a run costs nothing from the
subscription bank. It needs bash 3.2+ and `jq`.

- Rows are deduplicated by `message.id` (one message streams as several rows
  that repeat one usage object) and sorted by timestamp.
- A **full-prefix rewrite** is a turn whose `cache_read` falls below half the
  previous turn's while `cache_creation` carries the load.
- A rewrite is explained away as `compacted` (a compaction row between the
  turns, or the context shrank by more than 25 %) or `ttl` (the gap reached the
  session's cache TTL). Only an unexplained rewrite is `invalidated`.
- The TTL is per session: 3600 s when the last cache write used the 1-hour tier,
  else 300 s.
- `read-ratio` is `cache_read / (input + cache_read + cache_creation)` over
  every counted turn of every file given.

## What each probe measures

| Probe | Question | Verdict | Exit codes |
|---|---|---|---|
| `invalidation --event <time>` | Did an event (an edit, a bank reset) rewrite the cache of sessions live across it? Only the first turn after the event is judged. | `not-invalidated` / `invalidated` / `inconclusive` | 0 / 1 / 2 |
| `idle-gap` | Does an idle gap at or past the TTL re-pay the prefix, and a shorter one not? | `ttl-consistent` / `ttl-inconsistent` / `inconclusive` | 0 / 1 / 2 |
| `first-turn` | Does a session's first request read a warm shared prefix, or start cold? | `warm-start` / `cold-start` | 0 / 1 (2 = no sessions) |
| `scripts/eval/harness-run.py` | Does a judge or differential harness leave **no** descendant process behind, under a hard deadline? (Not a cache probe: it shares the `scripts/eval/` home and the "no claim without a check" rule.) | fixture suite pass/fail | 124 deadline, 125 survivor |

Exit code 64 is a usage error for `cache-probe.sh`.

## Results (2026-10-06)

Input: 2,019 session transcripts of one project (about 51 billion tokens
counted), read from `~/.claude/projects/<project-dir>/*.jsonl`. No transcript
content is in this repo; the probe prints only ids, counts and token totals.

| Probe | Command | Result |
|---|---|---|
| `first-turn` | `first-turn <all sessions>` | `warm-start warm=1966 cold=19`, read-ratio 98.3 % |
| `idle-gap` | `idle-gap <all sessions>` | `ttl-consistent`: cold-expected=172, cold-rewrote=155; warm-expected=25056, warm-rewrote=46; read-ratio 98.3 % |
| `invalidation` | `--event 2026-10-05T16:00:00Z <all sessions>` (a weekly-bank reset at 100 %, same account) | `not-invalidated kept=2 invalidated=0 compacted=0 ttl=0 inconclusive=0`, read-ratio 98.1 % |
| `test-cache-probe.sh` | fixture suite | 59 passed, 0 failed |
| `test-harness-run.sh` | fixture suite | PASS |

How to read it:

- A new session starts warm in 1,966 of 1,985 cases (99.0 %). The 19 cold ones are
  sessions whose first request found no warm prefix.
- Gaps past the TTL rewrote the prefix in 155 of 172 cases (90 %); gaps inside
  it rewrote in 46 of 25,056 (0.18 %). That is the cost of a parked session: the
  wake re-pays the prefix, and an idle one costs nothing.
- The 2026-10-05 bank reset did not invalidate the two sessions live across it
  (317.5k to 319.5k read over a 2,101 s gap; 155.0k to 119.1k read with a 15.8k
  write over 1,605 s, still above half).
- Compared with the 2026-09-29 run in the internals doc, the counts grew with
  the transcripts (1,210 to 1,985 first turns, 98.2 % to 98.3 %), and the
  `invalidation` result is the same as the earlier L5 row to the token.

## Cost

Zero model calls. `cache-probe.sh` and both fixture suites read local files
only; a probe over all 2,019 transcripts took roughly one to two minutes per mode on one
core, and the fixture suites take under 10 s. Bank preflight
(`bash scripts/lib/bank-preflight.sh`) printed `PROCEED` at 18 % of the 5-hour
and 45 % of the weekly bank before the runs, which only matters for the other
evals in this directory that do call a model.

## Limitations

- The rewrite and compaction thresholds are fixed (read below 0.5x the previous
  turn, create above read, context drop above 25 %). They separate the fixtures
  and these measurements; a workload with a much smaller prefix could sit near
  them.
- One TTL tier per session, inferred from `usage` and not from the request. A
  session that mixes tiers can read as over-flagged, never as hidden.
- A partial-prefix invalidation that keeps at least half the previous read looks
  like `kept`. The probe rules out a full rewrite, not a partial one.
- Only the first transition after the event is judged; timestamps are whole
  seconds (a gap is plus or minus 1 s).
- Helper calls that never reach the transcript are invisible, so `first-turn`
  can read warm from a call the file does not show.
- Single project, single account, one host. No account switch has been measured.
  Four audit claims remain UNVERIFIED (see the internals doc).
- Counts depend on which transcripts exist on the machine; re-running later or
  elsewhere gives different totals. The verdicts, not the totals, are the
  stable part.

## Re-run

```bash
# fixture suites (deterministic, no live data)
bash scripts/quiet-run.sh suite -- bash scripts/eval/test-cache-probe.sh
bash scripts/quiet-run.sh suite -- bash scripts/eval/test-harness-run.sh

# live probes over your own transcripts (read-only, no model call)
P=~/.claude/projects/<project-dir>
bash scripts/eval/cache-probe.sh first-turn $P/*.jsonl
bash scripts/eval/cache-probe.sh idle-gap $P/*.jsonl
bash scripts/eval/cache-probe.sh invalidation --event 2026-10-05T16:00:00Z $P/*.jsonl
```

For `--event`, give an epoch, an ISO time, or `@<file>` to use that file's
mtime. Sessions not live on both sides of the event are skipped.
