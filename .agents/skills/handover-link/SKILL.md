---
name: handover-link
description: Report or check where Claude reads/writes handover state (inline ./handovers or external $HANDOVER_DIR). Use when the user asks where handover state lives or runs /handover-link.
---

# handover-link

When the user asks where handover state lives (or to check the link), run:

    bash scripts/handover-link.sh [status|doctor]

Default verb is `status` (print resolved root + mode A-inline/B-external).
`doctor` exits non-zero on misconfiguration (CI/pre-push use). Note this script
is top-level (`scripts/handover-link.sh`), not under `scripts/handover/`. See
`.claude/commands/handover-link.md` for the mode A/B detail.
