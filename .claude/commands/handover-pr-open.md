---
description: Open or update the PR for the current handover/<TICKET>-<slug> branch (HIMMEL-141).
argument-hint: [--dry-run] [--base <branch>]
---

Opens a new PR (or updates an existing one) for the current handover branch.
Idempotent across re-runs. Body shape: `## Summary`, `## Files changed`, `## Ticket`.

Refuses (rc=3) if HEAD is not on a `handover/*` branch — this command is
scoped to the auto-commit branched flow (HIMMEL-140).

Run from the worktree of the handover repo (not from himmel root). The
script invokes `gh pr create` on first call and `gh pr edit` on subsequent
re-runs. PR-create failures are best-effort: the branch is still pushed
and the operator can open the PR manually later.

Run:

```bash
bash scripts/handover/pr-open.sh $ARGUMENTS
```

Common invocations:
- `/handover-pr-open` — open or update the PR for the current branch.
- `/handover-pr-open --dry-run` — preview the body + intended gh calls.
- `/handover-pr-open --base develop` — target a non-default base branch.

Environment:
- `HANDOVER_PR_AUTO=0` — skip entirely (no-op exit 0).
- `HANDOVER_PR_BASE=<ref>` — default base for new PRs.
- `GH_CMD=<cmd>` — override the gh binary (tests use `echo`).

Exit codes:
- `0` PR opened/updated/skipped (best-effort)
- `1` usage error
- `2` required tool missing
- `3` not on a handover/* branch (refuses)

`auto-commit.sh` invokes this script automatically after every push on
the branched path; manual invocation is only needed when you want to
refresh the PR body without committing.
