---
description: Create a new worktree under .claude/worktrees/ (no prune). Thin alias for /clean_garden --no-prune.
argument-hint: <branch-name> [--no-install] [--verbose] [--dry-run]
---

Create-only sibling of `/clean_garden`. Creates `.claude/worktrees/<type>+<slug>/` for the given branch.

Branch naming: `type/slug` where type ∈ feat|fix|chore|docs|refactor|test.

Run:

```bash
bash scripts/worktree.sh $ARGUMENTS
```

After the OK line, switch in (`cd <printed-path>`), do work, commit, push, open PR.

For the combined prune + create flow, use `/clean_garden <branch>`. For prune-only, use `/clean`.
