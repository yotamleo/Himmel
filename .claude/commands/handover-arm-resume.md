---
description: Arm the OS scheduler to relaunch claude at the given time with the given handover. Dedup-guarded. Direct schtasks/at invoke. HIMMEL-122.
argument-hint: --time <HH:MM|smart|auto> --handover <path> [--force] [--dry-run]
---

Actually create the scheduled relaunch (not just print the command — for the print-only flavor see `scripts/handover/schedule-resume.sh`). Wraps the platform scheduler (`schtasks` on Windows, `at` or `crontab` on POSIX) directly — does NOT shell out to `schedule-resume.sh` (whose stdout mixes prose with commands and isn't safe to `bash -c`).

## Guarantees
- **Dedup safeguard:** refuses (rc=3) if a `HIMMEL-Resume-*` job already exists. Pass `--force` to delete + replace.
- **Fail-closed:** if the dedup listing itself errors (schtasks denied, atd down), the script exits rc=2 rather than silently arming a duplicate.
- **POSIX dedup that actually works:** the `at` job body includes `# HIMMEL-Resume-<task_name>` as a comment line so `atq + at -c | grep` finds it. (v1 omitted this marker; dedup was dead.)
- **Windows path correctness:** the .bat indirection is written via `mktemp` and the path converted with `cygpath -w` for `schtasks`. (v1 emitted `%TEMP%\...` which bash left literal.)
- **Loud banner:** post-arm output explicitly tells operator to `/exit` so the cron relaunch doesn't compete with the still-open session.

Run:

```bash
bash scripts/handover/arm-resume.sh $ARGUMENTS
```

`--time` accepts a clock time OR a usage-aware sentinel (HIMMEL-204):
- **`smart`** (prefer this) — reads the claude-statusline usage cache and picks
  the slot that MAXIMIZES throughput: relaunch ASAP (now + a few min) when the
  bank has headroom, else wait for the binding window's reset. Don't space
  sessions out when quota is sitting idle. Logic: `scripts/handover/resume-slot.sh`.
- **`auto`** — the next 5-hour cap reset regardless of headroom
  (`scripts/handover/cap-reset-time.sh`). Use when you explicitly want to wait.
- **`HH:MM`** — explicit 24h local time; today if still future, else tomorrow.

All forms resolve to a concrete date+time, so a past `HH:MM` (and any
multi-day sentinel) is scheduled correctly — schtasks gets `/sd <date>`, `at`
gets `-t <stamp>` (fixes the old "time already passed today → never fires" bug).

Common invocations:
- `/handover-arm-resume --time smart --handover handovers/<USER_SLUG>/status.md`
- `/handover-arm-resume --time 07:22 --handover handovers/<USER_SLUG>/himmel/epics/HIMMEL-70-github-warp/next-session-12.md`
- `/handover-arm-resume --time auto --handover handovers/<USER_SLUG>/himmel/standalones/HIMMEL-44-windows-install-test/next-session.md --force`
- `/handover-arm-resume --time 14:00 --handover handovers/<USER_SLUG>/status.md --dry-run`

Exit codes: 0 armed, 1 usage error, 2 env unusable, 3 dedup block, 4 scheduler failed.

**Scope:** This is the *arm* half of HIMMEL-122; `smart` (HIMMEL-204) is the
usage-aware *detect* heuristic wired into the arm path.
