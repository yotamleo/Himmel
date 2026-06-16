---
description: Prune merged-PR worktrees (no create). Thin alias for /clean_garden --prune-only.
argument-hint: [--dry-run] [--verbose]
---

Prune-only sibling of `/clean_garden`. Removes any non-primary worktree whose PR is merged (preferred signal: `gh pr list --state merged`; falls back to `[gone]` branch tracking when gh is unavailable).

Safety:
- Never prunes the primary worktree.
- Never prunes a worktree with uncommitted changes — warns and skips.
- Never uses `git worktree remove --force`. Stuck records require a manual `git worktree remove --force <path>`.

Run:

```bash
bash scripts/clean.sh $ARGUMENTS
```

For the combined prune + create flow, use `/clean_garden <branch>`. For create-only, use `/worktree <branch>`.
