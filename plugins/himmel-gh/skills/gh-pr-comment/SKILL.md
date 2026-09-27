---
name: gh-pr-comment
description: Add a general PR comment, not a thread reply ("comment on PR 42 saying X"). Needs PR number. Not thread replies/Jira.
---

# gh-pr-comment

The user wants to add a general comment to a PR (top-level, not a thread reply).

Extract the PR number and body from the user's message. If the user is replying to a specific reviewer's thread, redirect to `/gh-pr-reply` instead. Otherwise run `/gh-pr-comment <N> "<body>"`. Output only the runner's one-line summary (the new comment's URL).
