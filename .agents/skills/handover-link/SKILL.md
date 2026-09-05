---
name: handover-link
description: Report where Claude reads/writes handover state (inline ./handovers or $HANDOVER_DIR). Use for /handover-link.
---

# handover-link

When the user asks where handover state lives (or to check the link), run:

    bash scripts/handover-link.sh [status|doctor]

Default verb is `status` (print resolved root + mode A-inline/B-external).
`doctor` exits non-zero on misconfiguration (CI/pre-push use). Note this script
is top-level (`scripts/handover-link.sh`), not under `scripts/handover/`. See
`.claude/commands/handover-link.md` for the mode A/B detail.
