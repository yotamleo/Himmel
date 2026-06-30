---
name: handover-arm-resume
description: Arm the OS scheduler to relaunch claude at a given time with a given handover. Dedup-guarded. Use when the user asks to arm a resume / schedule a relaunch or run /handover-arm-resume.
---

# handover-arm-resume

When the user asks to arm a scheduled resume, run:

    bash scripts/handover/arm-resume.sh --time <HH:MM|smart|auto> --handover <path> [--force] [--dry-run]

`--time smart` (prefer) reads the usage cache and picks the throughput-maximizing
slot; `auto` waits for the next cap reset; `HH:MM` is explicit local time.
Dedup-guarded: refuses (rc=3) if a `HIMMEL-Resume-*` job exists (use `--force` to
replace). This shells the SANCTIONED arm path — never hand-roll `schtasks`/`at`
(blocked by block-rogue-claude-schedule). See
`.claude/commands/handover-arm-resume.md` for the time sentinels + exit codes.
