---
allowed-tools: Bash(himmel-run:*), Bash(gh:*)
description: Add a general comment to a GitHub PR (NOT a thread reply — for thread replies use /gh-pr-reply). Returns one-line summary; comment URL in normal.log.
argument-hint: "<PR-number> \"<body>\""
---

## Your task

Run exactly:

```
himmel-run gh --summary-regex 'https?://\S+' -- gh pr comment "$1" --body "$2"
```

`gh pr comment` prints the comment URL on success; the runner's `--summary-regex` picks the URL up as the summary.

Output only the runner's one-line summary. Do not add commentary.
