---
allowed-tools: Bash(himmel-run:*), Bash(gh:*)
description: Show one GitHub PR. Returns one-line summary (title | state | mergeable). Full JSON in normal.log.
argument-hint: "<PR-number>"
---

## Your task

Run exactly:

```
himmel-run gh --summary-jq '.title + " | " + .state + " | " + (.mergeable // "?")' -- gh pr view "$1" --json state,title,url,mergeable
```

Output only the runner's one-line summary. Do not add commentary. If the user asks for details, read `~/.cache/himmel-cli/gh/normal.log` (POSIX) / `%LOCALAPPDATA%\himmel-cli\gh\normal.log` (Windows) or run `himmel-run gh --inspect <run-id>`.
