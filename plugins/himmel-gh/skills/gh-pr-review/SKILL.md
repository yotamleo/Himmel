---
name: gh-pr-review
description: Submit a PR review verdict: approve/request-changes/comment ("approve PR 42"). Needs verdict. Not plain comments.
---

# gh-pr-review

The user wants to submit a review on a specific PR.

Extract the PR number and the verdict (approve / request-changes / comment) from the user's message; if the verdict is unclear, ask via AskUserQuestion. Then run `/gh-pr-review <N> --<verdict> --body "<body>"`. Output only the runner's one-line summary.
