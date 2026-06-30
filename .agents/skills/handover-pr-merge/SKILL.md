---
name: handover-pr-merge
description: Squash-merge the PR for the current handover/<TICKET>-<slug> branch. Plain merge (no --admin by default). Use when the user asks to merge the handover PR or run /handover-pr-merge.
---

# handover-pr-merge

When the user asks to merge the handover PR, run:

    bash scripts/handover/pr-merge.sh [--dry-run]

Fires a plain `gh pr merge <N> --squash --delete-branch` for the open PR on the
current handover branch — no `--admin` (that fallback needs explicit
`GH_ADMIN_MERGE_OK=1`; the script never silently escalates). Refuses (rc=3) if
HEAD is not on a `handover/*` branch. Run from the worktree of the handover repo.
Run after `handover-flush` or at session-end. See
`.claude/commands/handover-pr-merge.md` for env vars + exit codes.
