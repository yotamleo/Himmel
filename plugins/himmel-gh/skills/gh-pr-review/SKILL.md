---
name: gh-pr-review
description: Use when user asks to review a GitHub PR with a verdict — approve, request changes, or post a review comment ("approve PR 42", "request changes on #97", "leave a review on PR 100", "review PR 5 with comment"). MUST reference a PR number and an explicit review action. Do NOT trigger on Jira (HIMMEL-N → himmel-jira). Do NOT trigger on "leave a comment on PR" without verdict (that's /gh-pr-comment, plain comment).
---

# gh-pr-review

The user wants to submit a review on a specific PR.

Extract the PR number and the verdict (approve / request-changes / comment) from the user's message; if the verdict is unclear, ask via AskUserQuestion. Then run `/gh-pr-review <N> --<verdict> --body "<body>"`. Output only the runner's one-line summary.
