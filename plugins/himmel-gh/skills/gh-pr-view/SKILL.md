---
name: gh-pr-view
description: View a specific GitHub PR by number ("PR 97", "#42"). Not Jira keys, branches, commits, or issues without PR context.
---

# gh-pr-view

The user wants a one-line summary for a specific GitHub PR.

Extract the PR number from the user's message (e.g. "PR 97" → `97`, "#42" → `42`) and run `/gh-pr-view <N>`. Output only the runner's one-line summary. If the user asks for more detail (description body, comments, files), follow up with the appropriate `gh` call — but the default response is the one-liner.

If it is unclear whether N is a Jira ticket or a PR (e.g. "show me 97" right after a Jira exchange), ask rather than guess — the two runners hit different systems.
