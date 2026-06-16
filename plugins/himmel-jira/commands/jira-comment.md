---
allowed-tools: Bash(himmel-run:*), Bash(node:*)
description: Add a comment to a Jira issue. Returns one-line "comment added" summary. Supports --attach <path> (repeatable, attaches to the parent issue — Jira attachments are issue-scoped, not comment-scoped).
argument-hint: "<KEY> \"<body>\" [--attach path]..."
---

> **Note (Windows):** the body uses bash parameter expansion / subshell syntax. Claude Code's `Bash` tool invokes Git Bash on Windows — works as long as Git Bash is on PATH (which it is when this repo's `setup/win11.ps1` ran successfully).

## Your task

```
himmel-run jira --summary-regex '(comment added|OK)' -- node $CLAUDE_PROJECT_DIR/scripts/jira/dist/index.js comment "$1" "$2" "${@:3}"
```

Pass `--attach <path>` (repeatable) through after `$2`. Attachments land on the parent issue `$1`.
