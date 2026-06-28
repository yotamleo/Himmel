---
name: clean-garden
description: Prune merged-PR worktrees AND create a new one in one shot. Use when the user asks to run /clean_garden or prune-and-create a worktree.
---

# clean-garden

When the user asks to prune-and-create, run:

    bash scripts/clean-garden.sh <branch-name> [--no-prune] [--prune-only] [--no-install] [--dry-run]

`<branch-name>` is `type/slug`. Summarize prunes, then the created worktree path.
