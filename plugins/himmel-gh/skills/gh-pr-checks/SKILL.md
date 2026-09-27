---
name: gh-pr-checks
description: CI/check status for a specific PR ("is PR N passing", "CI status for #97"). Needs a PR number. Not Jira or local checks.
---

# gh-pr-checks

The user wants CI check status for a specific PR.

Extract the PR number from the user's message and run `/gh-pr-checks <N>`. Output only the runner's one-line summary (e.g. `3 pass, 1 fail`). If the user asks which specific check failed, follow up with `~/.cache/himmel-cli/gh/normal.log` (POSIX) or `%LOCALAPPDATA%\himmel-cli\gh\normal.log` (Windows) — or run `himmel-run gh --inspect <run-id>` for the per-check JSON.
