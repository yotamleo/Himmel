---
description: Arm the OS scheduler to relaunch claude at the given time with the given handover. Dedup-guarded. Direct schtasks/at invoke. HIMMEL-122.
argument-hint: --time <HH:MM|smart|auto> --handover <path> [--force] [--dedup-any] [--dry-run]
---

Actually create the scheduled relaunch (not just print the command — for the print-only flavor see `scripts/handover/schedule-resume.sh`). Wraps the platform scheduler (`schtasks` on Windows, `at` or `crontab` on POSIX) directly — does NOT shell out to `schedule-resume.sh` (whose stdout mixes prose with commands and isn't safe to `bash -c`).

## Guarantees
- **Dedup safeguard is PER-HANDOVER (HIMMEL-340), not prefix-wide:** it refuses (rc=3) only when a resume job for *this same handover* is already scheduled — matched on the handover-derived `$TASK_NAME`, not on the `HIMMEL-Resume-` prefix. Pass `--force` to delete + replace (a `--force` replace is scoped to this handover's job; sibling slots survive). **Distinct handovers arm concurrently by design** — N tickets each get their own slot, so you never have to serialise two independent tickets or `--force` over one to queue the other. `--dedup-any` opts back into the broad "defer to ANY existing resume slot" semantics; that is the unattended auto-arm watchdog's safety-arm mode, not the operator path. **The identity is CANONICAL since HIMMEL-1304** — it is derived from the resolved handover path plus a short hash of it, which closes both directions the pre-1304 sanitized-raw-path form was lossy in:
  - *Same file, two spellings → ONE slot.* `x.md`, `./x.md`, an absolute path, a `..` detour, a symlink, and (on Windows) a `C:/…` vs `/c/…` vs case variant all resolve to the same identity, so a re-arm matches its own slot instead of arming a second one. You no longer have to pass the path consistently for dedup to hold.
  - *Two files, two identities.* The readable half of the name still strips characters outside `[:alnum:]_-`, but uniqueness now rides on a hash of the canonical path, so genuinely distinct paths that sanitize alike (`.../a+b.md` vs `.../ab.md`) no longer collapse into a false rc=3 "duplicate" — and `--force` can no longer replace the *other* handover's slot.
  - *Upgrade migration:* dedup matches the current identity **or** the pre-1304 one, so a slot armed before the upgrade is still found and still replaced by `--force` rather than being orphaned into an unseen second fire.
  - *Not yet canonical:* the cross-machine arms-registry (rc=8) still keys on the raw path as recorded, so two hosts that spell the same handover differently can still miss each other. Tracked separately — the registry key format is a cross-script contract shared with `queue-lock.sh`.
- **Time collision, not dedup, is what guards the clock (HIMMEL-407) — and only on some backends:** arming a *different* handover at the exact minute another `HIMMEL-*` task fires refuses rc=6; within `COLLISION_WINDOW_MINUTES` (default 5) it only WARNs and proceeds. **This holds for `schtasks` (Windows) and `crontab` only.** The POSIX `at` queue is deliberately NOT inspected — `atq` exposes no per-job fire time in a portably parseable form (`arm-resume.sh:1351-1354`) — so on a Linux host with `atd` running, where arms go to `at`, two handovers can be armed for the same minute with **no rc=6 and no WARN**. Treat collision detection as best-effort there. `--force` bypasses both — and so does **`--dedup-any`, which downgrades even an exact-minute collision to a WARN** and proceeds, because an unattended watchdog arm must never refuse. Past `ARM_MAX_SLOTS` (default 4) concurrent slots you get a soft WARN — never a block. Note `--dedup-any --force` is still the broadest combination: its dedup scope matches *every* resume job, so `--force` replaces them all, not just one. **The replace is transactional since HIMMEL-1304** — the deletion now runs only AFTER the new job is registered and its post-arm `NextRunTime` verify passes, so an arm that refuses (rc 7 queue lock, rc 8 cross-host registry) or fails inside `schedule_arm` leaves every existing slot untouched instead of wiping them with no replacement. If the new job registers but a superseded sibling cannot be deleted, the arm STANDS and the leftover is reported loudly for manual pruning — the failure can no longer read as "no arm" when an arm exists.
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
