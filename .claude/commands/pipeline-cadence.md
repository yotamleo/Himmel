---
description: Arm/inspect/remove the recurring clip-pipeline cadence (weekly /synthesize-clips + /archive-clips, monthly /obsidian-health) via schtasks (Windows) or cron (POSIX), interactive-claude shaped. Dedup-guarded. HIMMEL-255/265.
argument-hint: arm|status|disarm [--synth-day DAY] [--synth-time HH:MM] [--health-day N] [--health-time HH:MM] [--vault PATH] [--force] [--dry-run]
---

Register the luna clip-pipeline's recurring maintenance runs with the OS
scheduler (Windows `schtasks` — HIMMEL-255; Linux/macOS user crontab —
HIMMEL-265). Follows the `arm-resume.sh` precedent (HIMMEL-122): direct
scheduler invoke, dedup guard, runner indirection (`.bat` with
`cygpath`-converted paths on Windows; `.sh` with `printf %q`-quoted
values on POSIX, crontab entries marker-tagged `# HIMMEL-Pipeline-*`).

Armed defaults (operator decision pinned on HIMMEL-255, overridable via flags):

| Task | Schedule | Runs |
|---|---|---|
| `HIMMEL-Pipeline-Synthesize` | weekly Sun 03:00 | `/synthesize-clips`, then `/archive-clips` chained in the same session |
| `HIMMEL-Pipeline-Health` | monthly 1st 04:00 | `/obsidian-health` |

Each task launches a **bounded interactive** claude session in the luna
vault — `claude --settings <fragment> "<prompt>" < NUL` (the `< /dev/null`
bounded-run primitive). NOT `claude -p`/`--print`: headless invocations bill to
the separate Agent SDK bucket from 2026-06-15 (HIMMEL-128); this stays on Max
quota and passes the `no-headless-claude` gate without a marker.

**Auto-approve injection (HIMMEL-575).** The runs fire in the luna vault cwd,
which has no himmel `.claude/settings.json` — so without help, an autonomous run
would STALL on the HIMMEL-203 compound-bash permission prompt (the static
matcher bails on any `$var`/`$()`/pipe/compound command, and a `< NUL` run has
nobody to answer the prompt). At **arm time** the runner writes a tiny
`cadence-settings.json` next to the `.bat`/`.sh` that wires himmel's
`auto-approve-safe-bash` PreToolUse hook by **absolute path**, and each run is
launched with `--settings <that fragment>`. The hook only ever *grants* (it
never blocks), so this widens nothing the block-* deny hooks guard — it just
restores the auto-approve posture in the luna cwd. The fragment is created on
`arm` and removed on `disarm`.

## Guarantees
- **Dedup safeguard:** `arm` refuses (rc=3) if any `HIMMEL-Pipeline-*` task
  already exists; `--force` deletes + replaces (never duplicates).
- **Fail-closed:** any nonzero rc from the dedup listing (`/query` on
  Windows, `crontab -l` on POSIX) is fatal (rc=2, stderr printed) UNLESS
  it matches the one trusted empty signature (rc=1 with empty stderr;
  POSIX also trusts the standard `no crontab for <user>` stderr) — a
  failed listing is never silently treated as "nothing armed", so arm
  can't overwrite an armed cadence it failed to see.
- **Fire-time evidence:** each runner writes claude output to a `.log`
  next to it (`pipeline-synthesize.log` / `pipeline-health.log`),
  rotated per fire (previous run kept as `.log.prev`), stamped
  `[fired <date> <time>]` and capturing `cd` errors — the log exists on
  every fire even if the vault moved; `status` surfaces each log's mtime +
  last line, so "armed but never succeeding" is visible.
- **Persistent runners:** the `.bat`/`.sh` runners live in
  `~/.claude/pipeline-cadence/` (not `%TEMP%`/`/tmp` — cleanup sweeps
  would silently kill a recurring task).
- **Cron-safe by design:** every pipeline stage is idempotent (markers:
  `harvested_at`, `processed`, synthesis dedup window, `_done/` move), so a
  fired run that finds nothing to do exits clean.

Run:

```bash
bash scripts/luna/pipeline-cadence.sh $ARGUMENTS
```

Common invocations:
- `/pipeline-cadence status`
- `/pipeline-cadence arm`
- `/pipeline-cadence arm --synth-day MON --synth-time 02:30 --force`
- `/pipeline-cadence arm --dry-run`
- `/pipeline-cadence disarm`

Exit codes: 0 done, 1 usage error, 2 env unusable (no
`schtasks`/`crontab`, unknown platform, failed `/query`/`crontab -l` —
also from `status` when any query errors), 3 dedup block, 4 scheduler
invocation failed (`/create`, `/delete`, crontab rewrite, path
conversion).
