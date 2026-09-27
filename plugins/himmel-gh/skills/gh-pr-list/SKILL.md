---
name: gh-pr-list
description: List/count open GitHub PRs ("list PRs", "show open pull requests"). Add --author "@me" for "my PRs". Not Jira list.
---

# gh-pr-list

The user wants a count + summary of open PRs in the current repo.

Run `/gh-pr-list` — append `--author "@me"` if the user said "my" / "mine" / "I opened" (gh has no `--mine` flag; `--author "@me"` is the idiomatic substitute). Output only the runner's one-line summary (e.g. `3 open PR(s)`). For the full list (numbers + titles), point the user at `~/.cache/himmel-cli/gh/normal.log` (POSIX) or `%LOCALAPPDATA%\himmel-cli\gh\normal.log` (Windows).
