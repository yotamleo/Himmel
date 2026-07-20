---
description: Squash-merge the PR for the current handover/<TICKET>-<slug> branch (HIMMEL-141).
argument-hint: [--dry-run]
---

Fires a PLAIN `gh pr merge <N> --squash --delete-branch` against the open
PR associated with the current handover branch — no `--admin` (HIMMEL-224:
the admin flag bypasses nothing on this repo yet trips the auto-mode
classifier's hard veto). `--admin` exists only as a fallback on a
non-cosmetic plain-merge failure AND requires explicit authorization via
`GH_ADMIN_MERGE_OK=1`; the script never silently escalates. Squash is the
only allowed merge mode (repo settings forbid merge-commits as of 2026-05-25).

Refuses (rc=3) if HEAD is not on a `handover/*` branch.

Run from the worktree of the handover repo (not from himmel root).

Run:

```bash
bash scripts/handover/pr-merge.sh $ARGUMENTS
```

Common invocations:
- `/handover-pr-merge` — plain squash + delete-branch the open PR for HEAD.
- `/handover-pr-merge --dry-run` — print the intended gh call without invoking.

The script suppresses the cosmetic `failed to run git: fatal: 'main' is
already used by worktree` error that gh prints when the local branch
delete trips on a held worktree — the remote PR is merged either way.

Environment:
- `GH_CMD=<cmd>` — override the gh binary (tests use `echo`).
- `GH_ADMIN_MERGE_OK=1` — authorize the `--admin` fallback on a
  non-cosmetic plain-merge failure (default off).

Exit codes:
- `0` merged (or no PR found — nothing to do)
- `1` usage error
- `2` required tool missing
- `3` not on a handover/* branch (refuses)
- `4` gh pr merge failed (non-cosmetic)

Run after `/handover-flush` (HIMMEL-143) or at session-end to land the
handover branch.
