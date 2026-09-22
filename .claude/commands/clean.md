---
description: Prune merged-PR worktrees (no create). Thin alias for /clean_garden --prune-only.
argument-hint: [--only <path|branch>] [--dry-run] [--verbose]
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

To prune exactly ONE worktree (e.g. wrapping a single leg), pass `--only <worktree-path|branch>`: every gate above still applies, the fleet-wide sweeps are skipped, and it exits non-zero when the target is not a prune candidate. Prefer it over a bare `/clean` whenever other sessions may be live.

For the combined prune + create flow, use `/clean_garden <branch>`. For create-only, use `/worktree <branch>`.
