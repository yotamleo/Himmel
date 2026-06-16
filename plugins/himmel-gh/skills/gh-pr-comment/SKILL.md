---
name: gh-pr-comment
description: Use when user asks to add a general comment to a PR (NOT a reply to a review thread) — phrases like "leave a comment on PR 42", "add a note to #97", "comment on PR 100 saying X". MUST reference a PR number. Do NOT trigger on "reply to that review thread" (→ /gh-pr-reply), "approve PR" (→ /gh-pr-review), or Jira comment requests (HIMMEL-N → /jira-comment).
---

# gh-pr-comment

The user wants to add a general comment to a PR (top-level, not a thread reply).

Extract the PR number and body from the user's message. If the user is replying to a specific reviewer's thread, redirect to `/gh-pr-reply` instead. Otherwise run `/gh-pr-comment <N> "<body>"`. Output only the runner's one-line summary (the new comment's URL).
