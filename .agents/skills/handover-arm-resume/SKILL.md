---
name: handover-arm-resume
description: Arm the OS scheduler to relaunch claude at a given time with a given handover. Dedup-guarded. Use when the user asks to arm a resume / schedule a relaunch or run /handover-arm-resume.
---

# handover-arm-resume

When the user asks to arm a scheduled resume, run:

    bash scripts/handover/arm-resume.sh --time <HH:MM|smart|auto> --handover <path> [--force] [--dedup-any] [--dry-run]

`--time smart` (prefer) reads the usage cache and picks the throughput-maximizing
slot; `auto` waits for the next cap reset; `HH:MM` is explicit local time.
Dedup is PER-HANDOVER, not prefix-wide: it refuses (rc=3) only when a resume job
for THIS SAME handover is already scheduled (`--force` replaces the matched
job). Arming a DIFFERENT handover while another is queued SUCCEEDS —
independent tickets are meant to run concurrently, so never serialise them
or `--force` over one to queue the other. "Same handover" means the same
*derived task name*, which since HIMMEL-1304 is built from the CANONICAL
path plus a hash of it: every spelling of one file (relative, absolute,
`..`, symlink, and on Windows `C:/` vs `/c/` vs case) collapses to ONE
identity, and two distinct paths no longer collide just because punctuation
was stripped. A `--force` replace is also transactional — the old slot is
deleted only after the new job is registered and verified, so a later
refusal or failure can no longer leave you with no arm at all.
`--dedup-any` opts into the broad "any existing slot blocks" mode the
unattended auto-arm watchdogs use. This shells the SANCTIONED arm path —
never hand-roll `schtasks`/`at`
(blocked by block-rogue-claude-schedule). See
`.claude/commands/handover-arm-resume.md` for the time sentinels + exit codes.
