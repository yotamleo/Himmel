---
allowed-tools: Bash(node:*)
description: Re-fetch Jira metadata cache (projects, issue types, transitions).
---

## Your task

```
node $CLAUDE_PROJECT_DIR/plugins/himmel-jira/lib/init-cli.mjs --discover --projects HIMMEL,LUNA
```

Output the one-line summary only.
