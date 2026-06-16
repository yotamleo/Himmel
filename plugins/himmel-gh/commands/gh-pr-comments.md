---
allowed-tools: Bash(himmel-run:*), Bash(node:*), Bash(gh:*)
description: List review threads on a GitHub PR (open + resolved). Returns one-line `threads=N unresolved=M` summary; full table with 6-char prefixes goes to normal.log and writes the per-PR thread cache for /gh-pr-reply and /gh-pr-resolve.
argument-hint: "<PR-number>"
---

## Your task

First resolve repo context (cached after first call this session):

```
eval "$(node $CLAUDE_PROJECT_DIR/plugins/himmel-gh/lib/repo-context-cli.mjs)"
```

That sets shell vars `owner=...` and `name=...`. Then run:

```
himmel-run gh --summary-regex 'threads=(\d+ unresolved=\d+)' -- node $CLAUDE_PROJECT_DIR/plugins/himmel-gh/lib/threads-list-cli.mjs --owner "$owner" --repo "$name" --number "$1"
```

Output only the runner's one-line summary. Do not add commentary. The full thread table (including 6-char prefixes) is in `~/.cache/himmel-cli/gh/normal.log` (POSIX) / `%LOCALAPPDATA%\himmel-cli\gh\normal.log` (Windows). To act on a thread, copy its 6-char prefix and pass to `/gh-pr-reply` or `/gh-pr-resolve`.
