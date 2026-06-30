---
name: handover-flush
description: Session-end consolidation sweep across handover/* branches — push unpushed, open missing PRs, report merged. Use when the user asks to flush handover branches or run /handover-flush.
---

# handover-flush

When the user asks to flush handover branches, run:

    bash scripts/handover/flush.sh [--dry-run] [--cleanup] [--no-pr-open]

Walks every local `handover/*` branch in the resolved handover repo and
reconciles each against origin (push unpushed, open missing PRs, report merged;
`--cleanup` deletes branches that landed on main). Best-effort — exits 0 even on
per-branch errors. Report the per-branch status table. See
`.claude/commands/handover-flush.md` for detail.
