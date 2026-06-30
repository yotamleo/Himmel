---
name: handover-pr-open
description: Open or update the PR for the current handover/<TICKET>-<slug> branch. Idempotent. Use when the user asks to open/refresh the handover PR or run /handover-pr-open.
---

# handover-pr-open

When the user asks to open or update the handover PR, run:

    bash scripts/handover/pr-open.sh [--dry-run] [--base <branch>]

Opens a new PR or updates the existing one for the current handover branch
(idempotent). Refuses (rc=3) if HEAD is not on a `handover/*` branch. Run from
the worktree of the handover repo (not himmel root). See
`.claude/commands/handover-pr-open.md` for env vars (`HANDOVER_PR_AUTO`,
`HANDOVER_PR_BASE`, `GH_CMD`) + exit codes.
