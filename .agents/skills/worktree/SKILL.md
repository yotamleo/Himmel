---
name: worktree
description: Create a git worktree under .claude/worktrees/ for a type/slug branch (feat|fix|chore|docs|refactor|test). Use when the user asks to make a worktree or run /worktree.
---

# worktree

When the user asks to create a worktree, run:

    bash scripts/worktree.sh <branch-name> [--no-install] [--verbose] [--dry-run]

Branch must be `type/slug` (type ∈ feat|fix|chore|docs|refactor|test). After the
OK line, report the printed worktree path so the operator can `cd` in. For
prune+create use `clean-garden`; for prune-only use `clean`.
