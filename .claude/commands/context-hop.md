---
description: Mid-session jump to a fresh claude session when context window is approaching the soft budget. Sibling of /handover-arm-resume. HIMMEL-130.
argument-hint: [--message "what to pick up"] [--delay <minutes>] [--print] [--dry-run] [--force]
---

Operator-invoked context-hop: writes a snapshot to the handover root then either schedules a relaunch via `arm-resume.sh` (default) or prints the command to run manually (`--print`).

Use this when the current session is approaching ~75–80% of its context window and you want to /exit + pick up cleanly without losing state. Sibling of `/handover-arm-resume`:

- `/handover-arm-resume` is **cron-armed at a chosen future time** (typical usage: arm overnight when you stop work for the night, expecting to pick up tomorrow morning).
- `/context-hop` is **operator-invoked NOW** with a short delay (default 2 minutes) so the relaunch fires just after you /exit the current session. Same dedup safeguard + cd-into-repo + MSYS_NO_PATHCONV contract (inherits from `arm-resume.sh`, PRs #137 + #139).

## Snapshot

Written to `<handover-root>/context-hop-<UTC-timestamp>.md`. Body:

- Operator message (if `--message` passed) — short text describing what the hopped session should pick up.
- Origin context: cwd, git branch + HEAD short, pointer to `<handover-root>/next-session-resume.md` for the persistent next-session plan.
- Cold-start prompt block (used by the spawned claude on relaunch).

The snapshot is **NOT** a substitute for `next-session-resume.md` — it's a thin point-in-time pin so the hopped session knows what the immediately-prior session was doing. For long-running state, edit `next-session-resume.md` directly before hopping.

## Common invocations

```bash
# Default — schedule a relaunch in 2 minutes via arm-resume.sh
/context-hop --message "continuing PR #137 review; pick up at the cwd-fix verification step"

# Schedule sooner (1 min) and replace any existing HIMMEL-Resume-* job
/context-hop --message "..." --delay 1 --force

# Print mode — don't schedule, just write the snapshot + print the
# command to run in a fresh terminal manually
/context-hop --message "..." --print

# Dry-run — show what would be written + the command, touch nothing
/context-hop --message "..." --dry-run
```

Run:

```bash
bash scripts/handover/hop.sh $ARGUMENTS
```

## Handover root resolution

In priority order (HIMMEL-335):

1. `--handover-root <dir>` flag (used verbatim).
2. The shared resolver `scripts/lib/handover-path.sh` joined to `USER_SLUG` —
   `<HANDOVER_DIR or <repo>/handovers>/<USER_SLUG>`. `HANDOVER_DIR` /
   `USER_SLUG` are read from the launching shell or `<repo>/.env` (via
   `scripts/lib/load-dotenv.sh`).

Fails (`rc=2`) if neither resolves or the resolved root does not exist — no
hardcoded fallback path.

## Exit codes

- `0` — hop initiated (snapshot written + scheduled or printed).
- `1` — usage / input error.
- `2` — env unusable (no claude on PATH, no handover root resolvable).
- `3` — dedup block (existing HIMMEL-Resume-* and `--force` not passed in schedule mode).
- `4` — scheduler invocation failed (snapshot still written; resume manually).

## Scope

Spike covers the operator-invoked path. Auto-trigger at 75/80% context (the DETECT half) is a follow-up wedge — Claude doesn't have first-class access to its own context budget yet. Until then, the operator is the trigger.

## Prior stop-point (shared resolver)

Before writing the snapshot, surface the immediately-prior armed session's stop-point so the hop carries it forward (same resolver as `/handover-resume-armed`, HIMMEL-208):

```bash
bash scripts/handover/resume-armed.sh || true
```

Paste the one-line "Stopped at question / Agreed answer" into the snapshot's operator-message block when present. Non-fatal if it finds nothing.
