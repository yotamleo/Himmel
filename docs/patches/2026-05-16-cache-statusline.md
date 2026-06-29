# Patch: Cache Metrics Statusline

**Date:** 2026-05-16
**Repo:** `yotamleo/claude-statusline` (fork of `nilbuild/claude-statusline`)
**Branch merged:** `feature/cache-metrics` → `main`
**Upstream PR:** pending (not yet opened to `nilbuild/claude-statusline`)

---

## What this adds

Six new bash functions appended to `bin/statusline.sh` (inside a clearly marked section), wired into the main output after the existing rate-limit lines.

### New display lines

```
cache    ●●●●●●●●●○  59m41s
session  r:23.5M  w:783k  hit:99%  net +$62.88  cost $0.04
all      r:26.8M  w:965k  hit:99%  net +$71.57
```

- **cache line**: TTL countdown bar for the active cache tier. Green when fresh, red when near expiry. Drains left-to-right.
- **session line**: cache reads/writes/hit rate/net savings/session cost for the current transcript.
- **all line**: aggregated across all `~/.claude/projects/*/*.jsonl` files (30s cached).

### Functions added

| Function | Purpose |
|----------|---------|
| `format_tokens` | `45321 → "45k"`, `1234567 → "1.2M"` |
| `get_model_savings_rate` | Pricing table → sets `read_savings_rate`, `write_overhead_rate` |
| `compute_cache_ttl` | Last write ISO + TTL seconds → countdown string + bar % |
| `read_session_cache_stats` | jq-parses current session JSONL → reads/writes/inputs/timestamps |
| `read_all_sessions_cache_stats` | Scans all project JSONLs with 30s file cache |
| `build_cache_lines` | Assembles TTL + session + all-sessions display string |

---

## Pricing table (1h cache, as used by Claude Code)

| Model prefix | input $/MTok | cache_read $/MTok | cache_write $/MTok |
|---|---|---|---|
| claude-opus | 15.00 | 1.50 | 30.00 |
| claude-sonnet | 3.00 | 0.30 | 6.00 |
| claude-haiku | 0.80 | 0.08 | 1.60 |

Write price = 2× base (1h cache tier). Default 5m cache would be 1.25× but Claude Code always uses 1h.

---

## Data sources

- **Session stats**: `transcript_path` field from Claude Code's stdin JSON → `jq -s` on the JSONL file.
- **All-sessions stats**: `cat ~/.claude/projects/*/*.jsonl | jq -s ...` → cached 30s at `/tmp/claude/cache-all-stats.json`.
- **Cache tier timestamps**: `message.usage.cache_creation.ephemeral_1h_input_tokens` / `ephemeral_5m_input_tokens` fields in transcript entries.

---

## Tests

`test/test_cache.sh` — 39 tests, all passing. Run with `bash test/test_cache.sh` from the repo root.

The harness uses `sed` + `eval` to extract only the cache functions section from the script (avoids the blocking `input=$(cat)` at the top), with inlined copies of the deps (`iso_to_epoch`, `color_for_pct`, `build_bar`).

---

## Bottom-row period (HIMMEL-617)

The `all` bottom row is period-configurable via `HIMMEL_STATUSLINE_PERIOD`:

| Value | Window | Label |
|-------|--------|-------|
| `all` (default) | unbounded — every session ever | `all` |
| `week` | current ISO week, **Monday 00:00 local** to next Monday | `week` |
| `month` | current calendar month, 1st 00:00 to next 1st | `month` |

- Default `all` is byte-for-byte unchanged (it keeps the legacy
  `/tmp/claude/cache-all-stats{,-index}.json` files and the immutable
  per-file index path).
- An invalid value falls back to `all` (and warns once on stderr).
- `week`/`month` aggregate by **per-message `.timestamp`** within the window
  (not file mtime — resumed/multi-day sessions would mis-bucket), so the row
  resets cleanly at each boundary: a new window gets its own
  `cache-<window_id>.json` (e.g. `cache-week-20260622.json`,
  `cache-month-202606.json`), so a window flip is a cache miss → rebuild.
- ISO-Monday week start is intentional (matches ISO-8601 week numbering).
- Test seam: `HIMMEL_STATUSLINE_NOW` (epoch) overrides "now" so boundary
  tests can cross a week/month edge without faking the wall clock.

Deferred to a follow-up behind demonstrated need: `quarter | half | year |
range` (range also needs label-width/truncation handling v1 omits).

## Windows hacks

See `docs/tooling-catalog.md` → "Windows gotchas" section.

---

## Graceful fallbacks

- `transcript_path` missing or file not found → skip entire cache section silently.
- Model not in pricing table → sonnet defaults.
- All-sessions cache file unreadable → `all` line shows 0s.
- Cache writes = 0 for current session → skip TTL lines; still show session stats if reads exist.
