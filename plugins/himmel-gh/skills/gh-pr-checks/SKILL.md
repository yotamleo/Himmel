---
name: gh-pr-checks
description: Use when user asks about CI/check status for a specific GitHub PR ("is PR N passing", "are the checks green on PR 42", "CI status for #97", "did PR checks pass"). MUST reference a PR number. Do NOT trigger on generic "run CI" (no PR context) or on Jira (HIMMEL-N → himmel-jira). Do NOT trigger on "check git status" or "check pre-commit" (local, not CI).
---

# gh-pr-checks

The user wants CI check status for a specific PR.

Extract the PR number from the user's message and run `/gh-pr-checks <N>`. Output only the runner's one-line summary (e.g. `3 pass, 1 fail`). If the user asks which specific check failed, follow up with `~/.cache/himmel-cli/gh/normal.log` (POSIX) or `%LOCALAPPDATA%\himmel-cli\gh\normal.log` (Windows) — or run `himmel-run gh --inspect <run-id>` for the per-check JSON.
