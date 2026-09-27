---
name: gh-pr-resolve
description: Resolve/close a specific PR review thread by 6-char prefix ("resolve thread a3f2c1"). Not Jira or whole-PR close.
---

# gh-pr-resolve

The user wants to resolve a specific review thread on a PR.

Extract the prefix from the user's message and run `/gh-pr-resolve <prefix>`. Output only the runner's one-line summary. If the prefix is not in the cache, instruct the user to run `/gh-pr-comments <N>` first for that PR.
