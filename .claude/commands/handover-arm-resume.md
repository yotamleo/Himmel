---
description: Arm the OS scheduler to relaunch claude at the given time with the given handover. Dedup-guarded. Direct schtasks/at invoke. HIMMEL-122.
argument-hint: --time <HH:MM|smart|auto> --handover <path> [--force] [--dedup-any] [--dry-run]
---

Actually create the scheduled relaunch (not just print the command — for the print-only flavor see `scripts/handover/schedule-resume.sh`). Wraps the platform scheduler (`schtasks` on Windows, `at` or `crontab` on POSIX) directly — does NOT shell out to `schedule-resume.sh` (whose stdout mixes prose with commands and isn't safe to `bash -c`).

## Guarantees
- **Dedup safeguard is PER-HANDOVER (HIMMEL-340), not prefix-wide:** it refuses (rc=3) only when a resume job for *this same handover* is already scheduled — matched on the handover-derived `$TASK_NAME`, not on the `HIMMEL-Resume-` prefix. Pass `--force` to delete + replace (a `--force` replace is scoped to this handover's job; sibling slots survive). **Distinct handovers arm concurrently by design** — N tickets each get their own slot, so you never have to serialise two independent tickets or `--force` over one to queue the other. `--dedup-any` opts back into the broad "defer to ANY existing resume slot" semantics; that is the unattended auto-arm watchdog's safety-arm mode, not the operator path. **Caveats (HIMMEL-1304) — the identity is a *sanitized, uncanonicalized* form of the `--handover` path, so it is lossy in both directions:**
  - *Same file, two spellings → two slots.* The path is used as you typed it, so `x.md` vs `./x.md` vs an absolute path vs a symlink read as different handovers. Pass the path consistently — preferably absolute.
  - *Two files, one identity → a false dedup block.* Sanitization strips every character outside `[:alnum:]_-`, so genuinely distinct paths can collapse together (`.../a+b.md` and `.../ab.md` both reduce to `…abmd`). The second arm is then refused rc=3 as a "duplicate", and `--force` would replace the *other* handover's slot. Rare, but it is why the per-handover guarantee below is "matched on the derived name", not "provably one slot per file".
- **Time collision, not dedup, is what guards the clock (HIMMEL-407) — and only on some backends:** arming a *different* handover at the exact minute another `HIMMEL-*` task fires refuses rc=6; within `COLLISION_WINDOW_MINUTES` (default 5) it only WARNs and proceeds. **This holds for `schtasks` (Windows) and `crontab` only.** The POSIX `at` queue is deliberately NOT inspected — `atq` exposes no per-job fire time in a portably parseable form (`arm-resume.sh:1351-1354`) — so on a Linux host with `atd` running, where arms go to `at`, two handovers can be armed for the same minute with **no rc=6 and no WARN**. Treat collision detection as best-effort there. `--force` bypasses both — and so does **`--dedup-any`, which downgrades even an exact-minute collision to a WARN** and proceeds, because an unattended watchdog arm must never refuse. Past `ARM_MAX_SLOTS` (default 4) concurrent slots you get a soft WARN — never a block. Note `--dedup-any --force` is the one genuinely destructive combination: its dedup scope matches *every* resume job, so `--force` deletes them all, not just one — **and the deletion runs first**, before the rc 7 / rc 8 refusals and before the replacement is scheduled, so a failure after that point leaves you with no arm at all and no rollback (HIMMEL-1304 tracks making this transactional).
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

Exit codes: 0 armed, 1 usage error, 2 env unusable (includes a fail-closed dedup-listing error), 3 dedup block (same handover; or any slot under `--dedup-any`), 4 scheduler failed, 5 `--channels` refused while the bun Telegram bridge is live, 6 exact-minute time collision, 7 the handover's queue lock is FRESH (a session is live on it), 8 this handover already has a PENDING arm on another host.

**Scope:** This is the *arm* half of HIMMEL-122; `smart` (HIMMEL-204) is the
usage-aware *detect* heuristic wired into the arm path.
