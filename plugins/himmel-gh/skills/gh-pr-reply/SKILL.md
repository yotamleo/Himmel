---
name: gh-pr-reply
description: Reply to a specific PR review thread by 6-char prefix ("reply to thread a3f2c1"). Not general PR comments/Jira.
---

# gh-pr-reply

The user wants to post a reply to a specific PR review thread, identified by 6-char prefix from `/gh-pr-comments` output.

Extract the prefix and the reply body from the user's message. If the user has not yet run `/gh-pr-comments <N>` this session, instruct them to run it first so the prefix cache is populated. Then run `/gh-pr-reply <prefix> "<body>"`. Output only the runner's one-line summary.
