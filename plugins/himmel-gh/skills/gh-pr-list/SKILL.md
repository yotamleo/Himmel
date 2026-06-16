---
name: gh-pr-list
description: Use when user asks to list, enumerate, or count open GitHub PRs ("list PRs", "what PRs are open", "show me open pull requests", "list my PRs", "any open PRs"). MUST mention PR / pull request / "PRs". Add `--author "@me"` when user specifies "my" or "mine" (gh has no --mine flag). Do NOT trigger on Jira list ("jira tickets", "HIMMEL stories" → himmel-jira). Do NOT trigger on bare "list issues" without PR context.
---

# gh-pr-list

The user wants a count + summary of open PRs in the current repo.

Run `/gh-pr-list` — append `--author "@me"` if the user said "my" / "mine" / "I opened" (gh has no `--mine` flag; `--author "@me"` is the idiomatic substitute). Output only the runner's one-line summary (e.g. `3 open PR(s)`). For the full list (numbers + titles), point the user at `~/.cache/himmel-cli/gh/normal.log` (POSIX) or `%LOCALAPPDATA%\himmel-cli\gh\normal.log` (Windows).
