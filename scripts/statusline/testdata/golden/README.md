# Legacy statusline fixtures (HIMMEL-718 native-line parity)

Representative Claude Code statusline stdin payloads used to prove the forked
`claude-hud` renderer reproduces the legacy bash bar
(`scripts/statusline/bin/statusline.sh`). The parity gate is
[`scripts/statusline/test-hud-render-parity.sh`](../../test-hud-render-parity.sh).

## What is committed (stable, reusable)

- `fixture-*.json` — the statusline stdin payloads.
- `transcript-*.jsonl` — the tiny per-fixture session transcripts each payload's
  `transcript_path` points at (so session rows render without a real transcript).
- `usage-cache-extra.json` — an `extra_usage` consumer-cache sample for the
  `with-extra-usage` scenario.

These are pure inputs and never change between runs.

## Why the `.out` captures are NOT committed as golden

The legacy bar's full stdout is **non-deterministic**: alongside the
stdin-derived fields it renders wall-clock (session duration, usage-reset
countdown), the live session/all-session economics, and real git state — all of
which differ every render. A byte-for-byte `.out` capture therefore cannot be a
stable golden and is deliberately not committed.

Instead, `test-hud-render-parity.sh` asserts only the fields that are derived
purely from the stdin JSON and are therefore deterministic:

| field   | source (stdin)                              |
|---------|---------------------------------------------|
| model   | `model.display_name`                        |
| context | `context_window` token counts / window size |
| 5h %    | `rate_limits.five_hour.used_percentage`     |
| 7d %    | `rate_limits.seven_day.used_percentage`     |

The time-varying custom lines (where-are-we, economics, extra-usage/credits) are
proven separately in Task 3.2's composer parity test, since the composer hosts
them.

## Regenerating a legacy `.out` for manual comparison

If you want to eyeball the legacy bar for a fixture, capture to a scratch path
(do not commit it). Run from the repo root; the `HOME` override keeps the
no-rate-limit fixtures from reading real Claude credentials or project history,
and the seeded cache is only for `with-extra-usage`:

```bash
mkdir -p /tmp/claude
rm -f /tmp/claude/statusline-usage-cache.json
bash scripts/statusline/bin/statusline.sh \
  < scripts/statusline/testdata/golden/fixture-with-ratelimits.json

cp scripts/statusline/testdata/golden/usage-cache-extra.json /tmp/claude/statusline-usage-cache.json
bash scripts/statusline/bin/statusline.sh \
  < scripts/statusline/testdata/golden/fixture-with-extra-usage.json
```

Save and restore any real `/tmp/claude/statusline-usage-cache.json`,
`/tmp/claude/cache-all-stats.json`, and `/tmp/claude/cache-all-stats-index.json`
around such a run if they exist.
