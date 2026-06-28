---
name: clean
description: Prune merged-PR worktrees (no create). Use when the user asks to clean worktrees or run /clean.
---

# clean

When the user asks to prune merged worktrees, run:

    bash scripts/clean-garden.sh --prune-only

Summarize which worktrees were pruned and which were kept (and why). This only
prunes worktrees whose PR is merged; it never creates.
