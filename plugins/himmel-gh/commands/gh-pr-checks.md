---
allowed-tools: Bash(himmel-run:*), Bash(gh:*)
description: CI check status for a GitHub PR. Returns one-line summary grouped by bucket (e.g. "3 pass, 1 fail"). Full per-check JSON in normal.log.
argument-hint: "<PR-number>"
---

## Your task

Run exactly:

```
himmel-run gh --summary-jq '[.[] | .bucket] | group_by(.) | map("\(length) \(.[0])") | join(", ")' -- gh pr checks "$1" --json bucket
```

Output only the runner's one-line summary. Do not add commentary. If the user asks which specific checks failed, read `~/.cache/himmel-cli/gh/normal.log` (POSIX) / `%LOCALAPPDATA%\himmel-cli\gh\normal.log` (Windows) or run `himmel-run gh --inspect <run-id>` for full per-check detail.
