---
description: Session-end consolidation sweep across handover/* branches (HIMMEL-143).
argument-hint: [--dry-run] [--cleanup] [--no-pr-open]
---

Walks every local `handover/*` branch in the resolved handover repo
(per `HANDOVER_DIR`) and reconciles each against origin:

- **Unpushed** → `git push -u origin <branch>`.
- **No PR open** → invokes `scripts/handover/pr-open.sh`.
- **Merged into `origin/main`** (squash or merge-commit) → report by default;
  `--cleanup` deletes the local branch.

Prints a per-branch status table + footer summary. Exit 0 even on
per-branch errors — sweep is best-effort by design.

Run:

```bash
bash scripts/handover/flush.sh $ARGUMENTS
```

Common invocations:
- `/handover-flush` — push unpushed, open missing PRs, report merged.
- `/handover-flush --cleanup` — also delete local branches that landed on main.
- `/handover-flush --dry-run` — preview actions without touching state.
- `/handover-flush --no-pr-open` — skip the PR step when gh is offline.

Failure modes:
- `gh` missing or unauthenticated → warns + dumps the exact commands
  the operator must run to open each PR. Push step still runs.
- Per-branch push or PR failure → printed in the table; sweep continues
  to the next branch.

Wired into `/context-hop`: hop.sh calls flush.sh before writing the
snapshot so cap-resume hand-off cannot leave un-pushed handover state.

Smoke test: `bash scripts/handover/test-flush.sh` (14/14 pass).
