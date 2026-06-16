---
description: Open a new Warp tab at a directory, optionally pre-loading a command
argument-hint: <directory> [-- <command...>]
---

Open a Warp tab at `<directory>`. If a command follows `--`, pre-load it in the tab (Warp will type it but not execute).

Run:

```bash
bash scripts/open-in-warp.sh $ARGUMENTS
```

Quiet output by default — one OK/ERR line with the absolute path and the log. Pass `--verbose` before the directory for tee'd output.

Examples:
- `/open-warp .claude/worktrees/feat+squash-merge-detection`
- `/open-warp ~/my-repo -- npm test`
- `/open-warp . -- oz agent run "review PR #37"` (once `oz login` is done)

Use this when you want to pivot a long-running task into its own terminal window (so it doesn't block this Claude session) — e.g., spinning up `oz` cloud agents, running an interactive `claude` session, watching a dev server.
