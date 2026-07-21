# Vendored: claude-statusline

> **SUPERSEDED (HIMMEL-718 / HIMMEL-1233).** This vendored bash bar is no longer
> the wired statusline renderer — that role moved to the vendored claude-hud fork
> (`marketplace/plugins/claude-hud/`, a `node` process). `bin/statusline.sh` is
> **retained in-tree as the rollback fallback only**; its full decommission is a
> separate step gated on the HIMMEL-718 Phase-5 leak gate. The source fork
> `yotamleo/claude-statusline` is now **ARCHIVED**, so the fork-sync / re-vendor
> path below is closed — do not push edits back to it or re-vendor from it.

This directory is a **vendored copy** of the statusline, bound into himmel so
that himmel (and public-himmel) users get the status bar without cloning an
external repo or hand-editing global `~/.claude/settings.json`.

- **Source fork:** `yotamleo/claude-statusline` (origin, **archived**)
- **Upstream:** `nilbuild/claude-statusline` (`Kamran Ahmed`, MIT — see `LICENSE`)
- **Vendored at commit:** `3f64887` (`feat: mirror himmel-vendored statusline (jq degrade guard + period knob)`)
- **himmel cache-metrics patch:** `docs/patches/2026-05-16-cache-statusline.md`

> Partial mirror history (as of `3f64887`, 2026-07-04): the
> `HIMMEL_STATUSLINE_PERIOD` period knob (HIMMEL-617) and the fail-visible jq
> degrade guard (HIMMEL-612) were mirrored to `yotamleo/claude-statusline` with
> their `test_cache.sh` coverage. That closed the divergence for *those*
> patches — but the vendored tree is **not** fully synchronized: the HIMMEL-690
> label edits noted below were never mirrored (now moot, the fork is archived).
>
> **Pending mirror (HIMMEL-690) — OBSOLETE (HIMMEL-1233):** local
> `bin/statusline.sh` label edits (`current`→`5h bank`, `weekly`→`7d bank`, a
> `ctx` prefix on the context-window figure) were never mirrored to the fork.
> With the fork archived and the bar superseded by claude-hud, no mirror is owed
> — the divergence is intentionally left un-closed.

## What's here

| File | Purpose |
|------|---------|
| `bin/statusline.sh` | The status line script. Self-contained; reads Claude Code's stdin JSON, manages its own cache under `/tmp/claude`. |
| `test/test_cache.sh` | Cache-metrics test harness (the suite is the source of truth for the count). Run: `bash test/test_cache.sh`. Note: a few cache-healing cases read the live `/tmp/claude` usage cache, so they can report spurious failures on a machine with active Claude sessions; run against a clean `/tmp/claude` for a hermetic pass. |
| `LICENSE` | MIT, retained for attribution. |
| `README.md` | Upstream README (kept identical to the fork). |

Runtime deps: `jq`, `curl`, `git`. Not vendored from the fork: its own dev git
hooks (`scripts/hooks/`) and the npm installer (`bin/install.js`) — himmel
references the script directly rather than npm-installing it.

## Wiring

**Current (HIMMEL-718):** the `wire-statusline.{sh,ps1}` helpers point
`statusLine.command` at the claude-hud node renderer
(`node "<himmel-path>/marketplace/plugins/claude-hud/dist/index.js"`), NOT at
this bar. `unwire-statusline.sh` can repoint to the legacy bash wrapper
`<himmel-path>/scripts/where-are-we/statusline.sh` (which composes this vendored
`bin/statusline.sh` + a where-are-we line, HIMMEL-538) as a rollback fallback.
There is no external clone step.

## Keeping in sync with the fork — CLOSED

The `yotamleo/claude-statusline` fork is **archived** and this bar is superseded
by claude-hud (above), so the former "push edits back to the fork, pull
`nilbuild` fixes, re-vendor here" loop no longer applies. Do not re-vendor from
or push to the archived fork. Upstream-drift tracking for this component was
removed from `scripts/upstreams.json` (HIMMEL-1233).
