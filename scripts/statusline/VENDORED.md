# Vendored: claude-statusline

This directory is a **vendored copy** of the statusline, bound into himmel so
that himmel (and public-himmel) users get the status bar without cloning an
external repo or hand-editing global `~/.claude/settings.json`.

- **Source fork:** `yotamleo/claude-statusline` (origin)
- **Upstream:** `nilbuild/claude-statusline` (`Kamran Ahmed`, MIT — see `LICENSE`)
- **Vendored at commit:** `dd68f9b` (`fix(cache): incremental all-sessions scan + hide stale cache tier`)
- **himmel cache-metrics patch:** `docs/patches/2026-05-16-cache-statusline.md`

> **Local divergence pending re-vendor (HIMMEL-617):** `bin/statusline.sh` here
> carries the `HIMMEL_STATUSLINE_PERIOD` bottom-row period knob (week/month/all),
> which is **not yet in the fork**. This vendored copy is the deployed artifact,
> so the feature ships; but it MUST be mirrored to `yotamleo/claude-statusline`
> and the "Vendored at commit" SHA above bumped to the resulting fork commit on
> the next fork push. (The local-hash drift guard is a separate follow-up.)

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

`docs/setup/settings-template.json` and the `wire-statusline.{sh,ps1}` helpers
(used by `scripts/machine-setup/{win11.ps1,ubuntu.sh}`) point `statusLine.command`
at the himmel wrapper `<himmel-path>/scripts/where-are-we/statusline.sh`
(HIMMEL-538), which **composes this vendored `bin/statusline.sh` verbatim** and
appends one where-are-we line (active handover + epic progression). The vendored
file here is **not edited** by that feature — so it triggers no re-vendor
obligation. There is no external clone step.

## Keeping in sync with the fork

This copy is the deployed artifact. **Edits to `bin/statusline.sh` here must be
pushed back to `yotamleo/claude-statusline`** so the fork mirrors the
himmel-bound version (and stays a viable standalone / upstream-tracking repo).
Pull upstream `nilbuild` fixes into the fork first, then re-vendor here.
