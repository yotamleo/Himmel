# Upstream watch (HIMMEL-2367, HIMMEL-2426)

`scripts/upstreams/upstream-watch.sh` is a daily, delta-gated, zero-token scan
of the operator's open upstream PRs/issues. bash + `gh` + `jq` + `node`; it
never invokes claude. (`node` is used for exactly one thing — the handover-registry
lookup that resolves the report bucket — and is guarded with `command -v` like
the others, so a missing interpreter refuses with its own message instead of
misreporting as an unmatched registry entry. HIMMEL-2433 tracks replacing it
with jq, restoring the pure bash+gh+jq contract.) Armed via `scripts/upstreams/upstream-watch-cadence.sh` (one
daily scheduled task, default 06:00 local).

Each run builds the inventory of open PRs/issues authored by the operator
(across every tracked repo, excluding the operator's own), enriches every
item (comments, reviews, CI conclusion at the current head SHA, mergeable
state), diffs the result against the previous run's
snapshot (`$STATE_DIR/last_seen.json`), and — only on a delta — writes a
dated report and sends one Telegram line. A no-delta run touches nothing but
the state file and costs zero tokens.

## Report location

The report lands at:

```text
<handover-root>/<user>/<repo-bucket>/specs/reports/upstream-watch-<date>.md
```

the same bucketed layout every other report writer uses — never the bare
`<handover-root>/specs/reports/`. `handover_root` (`scripts/lib/handover-path.sh`)
is single-root by design (its own header says the bucket layer is applied by
callers), so this script resolves the `<user>/<repo-bucket>` segment itself,
the same way the rest of the handover system does: via the handover registry
(`${HANDOVER_REGISTRY:-~/.claude/handover/registry.json}`, shape
`{"repos": {"<key>": {"path": ..., "user": ..., "bucket_name": ...}}}`). It
matches the registry entry whose `path` is THIS checkout (resolved via the
script's own `resolve_himmel_root`, which honours `UPSTREAM_WATCH_HIMMEL_ROOT`
for tests) and uses that entry's `bucket_name` (falling back to the registry
key) plus its `user` (falling back to `user_slug()` when the entry carries
none). This mirrors — in the forward direction — the reverse (bucket → path)
lookup `arm-resume.sh` already does for its own HIMMEL-2147 fallback
(`scripts/handover/arm-resume.sh` around L2295).

**Path matching is the trap**: the registry stores paths Windows-style and
lowercase (`c:/users/<you>/...`), while `resolve_himmel_root` under Git Bash
returns MSYS-style (`/c/Users/<you>/...`). On **Windows** both sides are
normalized before comparing — backslash → `/`, strip trailing slash, fold a
leading `/c/` to `c:/`, then lowercase. Case folding and the drive-letter
fold are **Windows-only** (gated on `process.platform`): a Linux filesystem is
case-SENSITIVE, so folding there would let two genuinely different checkouts
that differ only by case match the same registry entry and route the report
into another repo's bucket.

`process.platform` is a proxy for case-sensitivity, not a measurement of it,
and the proxy is wrong on macOS — a default APFS/HFS+ volume is
case-INSENSITIVE (and a macOS volume can be formatted case-sensitive, and a
Linux host can mount a case-insensitive one), so a case-only path difference is
refused there rather than matched. That is the fail-CLOSED direction — exit 2,
state untouched, nothing misfiled — which is why it ships this way rather than
folding unconditionally. Comparing path IDENTITY (`stat` dev+ino) instead of
strings is the real answer and is tracked as
[HIMMEL-2449](https://yotamleo.atlassian.net/browse/HIMMEL-2449).

If the registry is missing, has no matching entry, the matched entry's user
cannot be resolved, or either resolved segment is not a single safe path
component (empty, `.`, `..`, or containing `/` or `\` — a registry value
walking the report out of `<handover-root>`), the run refuses (exit 2)
rather than guessing at a location, and the state file is left untouched so
the same delta is retried next run instead of being silently marked "seen"
with no report ever written for it.

## Exit codes

- `0` — ran clean, no delta.
- `10` — ran clean, delta found (report written + Telegram sent, best-effort).
- `2` — instrument failure: `gh` auth/rate-limit/parse failure on any call,
  the "0 items now vs >0 last-seen" positive-control refusal (never read that as
  "everything closed" — presume the instrument broke), a required render
  field (title/url) resolving null/empty, or a broken `handover_root` /
  report-bucket resolution / report-write on a run that DOES have a delta to
  report. In every one of the delta-but-failed cases, state is left
  UNTOUCHED — the inventory itself was fine, only the reporting step failed,
  and leaving state alone means the same delta is retried next run instead of
  being permanently marked "seen" with no report ever written for it.

## Windows: native `jq` writes CRLF

The native Windows `jq` (winget `jqlang.jq`) writes stdout in **text mode**:
`jq -r` emits `value\r\n`, not `value\n`. Command substitution strips only
the trailing *newline*; for a `jq -r` array dump (multiple lines), every line
but the last keeps its `\r`. That silently turned a `jq --arg k "$k"
'.[$k].title'` lookup into `null` for the report's first shipped run (every
row read `- [owner/repo#N](null) — null`) — the delta key list carried a
stray `\r` that never matched a real key.

The script guards this at a **single chokepoint**: a local `jq()` shell
function, defined once near the top of the script (right before `GH_BIN=`),
wraps every `jq` invocation in the file with `| tr -d '\r'`. Do not
additionally strip `\r` at individual capture sites — that treats the shim as
optional and invites its removal later. On Linux/macOS `jq` already emits LF
and the `tr` is a no-op.

As defense in depth, `build_report` also refuses outright (exit 2, state
untouched) if a required render field (title/url) still comes back
null/empty — so a null row can never render as `- [...](null) — null` again,
even from some future capture path this shim doesn't cover.

## Test seams

Used by `scripts/upstreams/test-upstream-watch.sh` (a fake `gh` driven by a
`world.json` fixture — see its header for the full harness):

- `UPSTREAM_WATCH_GH` — `gh` binary override.
- `UPSTREAM_WATCH_ME` — skip `gh api user`; use this login directly.
- `UPSTREAM_WATCH_STATE_DIR` — overrides the whole `.himmel/upstream-watch`
  dir.
- `UPSTREAM_WATCH_HIMMEL_ROOT` — overrides the resolved primary checkout,
  used for the Telegram `.env` lookup and as the path matched against the
  handover registry.
- `HANDOVER_DIR` / `HANDOVER_REGISTRY` — existing handover-system
  conventions; see `scripts/lib/handover-path.sh` and
  `scripts/handover/resolve-active-item.sh`.
