---
allowed-tools: Bash(himmel-run:*), Bash(node:*)
description: Show one Jira issue. Returns one-line summary (KEY, type, status, title).
argument-hint: "<KEY>"
---

## Your task

```
himmel-run jira --summary-regex '^([A-Z]+-\d+\s+\S+\s+\S+\s+.*)$' -- node $CLAUDE_PROJECT_DIR/scripts/jira/dist/index.js get "$1"
```
