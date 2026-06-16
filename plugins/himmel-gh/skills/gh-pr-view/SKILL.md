---
name: gh-pr-view
description: Use when user mentions a GitHub PR number (e.g. "#123", "PR 97", "pull request 42") or asks to view/show/check a specific pull request. MUST be a PR number — a bare integer with PR/pull-request context, or the # prefix. Do NOT trigger on Jira tickets (HIMMEL-N or any `[A-Z]+-\d+` pattern → himmel-jira). Do NOT trigger on "show me this branch" or "view this commit" without explicit PR reference. Do NOT trigger on "show issue N" without PR context (issue ≠ PR). When uncertain whether N refers to a Jira ticket or a GitHub PR (e.g. ambiguous "show me 97" right after a Jira context switch), ask the user — do not guess.
---

# gh-pr-view

The user wants a one-line summary for a specific GitHub PR.

Extract the PR number from the user's message (e.g. "PR 97" → `97`, "#42" → `42`) and run `/gh-pr-view <N>`. Output only the runner's one-line summary. If the user asks for more detail (description body, comments, files), follow up with the appropriate `gh` call — but the default response is the one-liner.
