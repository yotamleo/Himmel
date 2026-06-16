---
name: gh-pr-comments
description: Use when user asks to list, see, or read review threads/comments on a specific GitHub PR ("what comments are on PR 97", "show review threads on #42", "list unresolved threads on PR 100", "any open review comments on PR 5"). MUST reference a PR number. Do NOT trigger on Jira (HIMMEL-N → himmel-jira). Do NOT trigger on issue comments without PR context. Do NOT trigger on commit comments.
---

# gh-pr-comments

The user wants to see review threads on a specific PR (open + resolved).

Extract the PR number from the user's message and run `/gh-pr-comments <N>`. Output only the runner's one-line summary (e.g. `threads=5 unresolved=2`). If the user asks for the full table, read `~/.cache/himmel-cli/gh/normal.log` (POSIX) / `%LOCALAPPDATA%\himmel-cli\gh\normal.log` (Windows) — the per-thread 6-char prefixes shown there feed `/gh-pr-reply <prefix>` and `/gh-pr-resolve <prefix>`.
