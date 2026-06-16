---
allowed-tools: Bash(himmel-run:*), Bash(gh:*)
description: Submit a review on a GitHub PR (approve, request changes, or comment-only). Returns one-line summary; full gh response in normal.log.
argument-hint: "<PR-number> [--approve|--request-changes|--comment] --body \"<body>\""
---

## Your task

Run exactly (the PR number is `$1`; remaining flags are forwarded via
`"${@:2}"` so quoted args like `--body "long body with spaces"` survive
intact):

```
himmel-run gh --summary-regex 'review (added|posted|submitted)|Reviewed' -- gh pr review "$1" "${@:2}"
```

The previous shape (`gh pr review "$1" $@`) double-counted `$1` (since
`$@` already includes positional 1) and word-split unquoted args with
spaces. `"${@:2}"` skips position 1 and preserves spaces inside quoted
flag values.

Note: `gh pr review` requires one of `--approve`, `--request-changes`, or `--comment` plus `--body`. If the user did not specify a verdict flag, ask via AskUserQuestion which they want.

Output only the runner's one-line summary. If `gh pr review` returns no obvious confirmation string, the runner falls back to last-line of stdout (or `OK` if stdout is empty and exit code is 0 — per the runner's 6-tier summary extraction).
