---
name: gh-pr-reply
description: Use when user asks to reply to, respond to, or answer a specific PR review thread referenced by a short prefix or thread ID ("reply to thread a3f2c1", "respond to that review comment with X", "reply on #42 thread a3f2c1 saying fixed"). MUST reference a 6-char-or-longer hex prefix or thread node id. Do NOT trigger on "comment on PR" (general PR comment → /gh-pr-comment, no thread). Do NOT trigger on Jira comment requests.
---

# gh-pr-reply

The user wants to post a reply to a specific PR review thread, identified by 6-char prefix from `/gh-pr-comments` output.

Extract the prefix and the reply body from the user's message. If the user has not yet run `/gh-pr-comments <N>` this session, instruct them to run it first so the prefix cache is populated. Then run `/gh-pr-reply <prefix> "<body>"`. Output only the runner's one-line summary.
