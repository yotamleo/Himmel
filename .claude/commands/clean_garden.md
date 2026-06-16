---
description: Prune merged-PR worktrees and (optionally) create a new one in the same shot
argument-hint: [branch-name] [--prune-only] [--no-prune] [--no-install] [--dry-run] [--verbose]
---

Combined worktree gardener. Supersedes the legacy `/new-worktree` (removed in #39) and the plugin command `/clean_gone` (still installed via `commit-commands` plugin but superseded for himmel — use `/clean_garden` instead).

Default behavior: prune any non-primary worktree whose PR is merged (preferred signal: `gh pr list --state merged`; falls back to `[gone]` branch tracking when gh is unavailable). When a branch name is supplied, also creates the new worktree afterwards.

Safety:
- Never prunes the primary worktree.
- Never prunes a worktree with uncommitted changes — warns and skips.
- `--dry-run` shows the plan without touching anything.

Run:

```bash
bash scripts/clean-garden.sh $ARGUMENTS
```

Common invocations:
- `/clean_garden` — prune only (no create).
- `/clean_garden feat/foo` — prune merged + create `feat/foo` worktree.
- `/clean_garden --dry-run` — show what would be pruned.
- `/clean_garden feat/bar --no-prune` — skip prune, just create.
- `/clean_garden --prune-only` — same as no args; explicit form.

Single-purpose siblings (same orchestrator, mode flag pinned):
- `/clean` — prune-only (`clean-garden.sh --prune-only`). Use when you only want to clean up merged worktrees.
- `/worktree <branch>` — create-only (`clean-garden.sh --no-prune <branch>`). Use when starting a fresh feature without touching existing worktrees.

Branch naming for create: `type/slug` where type ∈ feat|fix|chore|docs|refactor|test. Worktree path is derived as `.claude/worktrees/<type>+<slug>`.

After the OK line for create, switch to the new worktree (`cd <printed-path>`), do work, commit with conventional message, push, open PR.
