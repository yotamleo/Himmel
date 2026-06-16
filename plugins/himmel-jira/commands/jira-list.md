---
allowed-tools: Bash(himmel-run:*), Bash(node:*)
description: List Jira issues in a project, optionally filtered by status. Returns one-line summary; full table in normal.log.
argument-hint: "[project] [status]"
---

> **Note (Windows):** the body uses bash parameter expansion / subshell syntax. Claude Code's `Bash` tool invokes Git Bash on Windows — works as long as Git Bash is on PATH (which it is when this repo's `setup/win11.ps1` ran successfully).

## Your task

Run exactly:

```
himmel-run jira --summary-regex '^(\d+) issues?' -- node $CLAUDE_PROJECT_DIR/scripts/jira/dist/index.js list ${1:+--project "$1"} ${2:+--status "$2"}
```

Output only the runner's one-line summary. Do not add commentary. If the user asks for details, read `~/.cache/himmel-cli/jira/normal.log` (POSIX) / `%LOCALAPPDATA%\himmel-cli\jira\normal.log` (Windows) (latest entries at bottom) or run `himmel-run jira --inspect <run-id>`.
