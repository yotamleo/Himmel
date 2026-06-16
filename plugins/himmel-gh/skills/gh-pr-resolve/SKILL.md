---
name: gh-pr-resolve
description: Use when user asks to resolve, close, or mark-done a specific PR review thread by 6-char prefix or thread node id ("resolve thread a3f2c1", "mark that review comment resolved", "close out thread a3f2c1 on #42"). MUST reference a 6-char-or-longer hex prefix or full thread id. Do NOT trigger on Jira "resolve ticket" / "close issue" (HIMMEL-N → himmel-jira transition Done). Do NOT trigger on "merge PR" or "close PR" (whole-PR ops, not thread-level).
---

# gh-pr-resolve

The user wants to resolve a specific review thread on a PR.

Extract the prefix from the user's message and run `/gh-pr-resolve <prefix>`. Output only the runner's one-line summary. If the prefix is not in the cache, instruct the user to run `/gh-pr-comments <N>` first for that PR.
