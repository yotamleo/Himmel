---
name: jira-create
description: File/create a new Jira ticket ("file a jira for X", "create a bug ticket"). Not GitHub PRs or issues.
---

Use the `/jira-create` slash command. Parse the user's request for type (Story/Bug/Task/Epic) and title; ask via AskUserQuestion if either is unclear. If type has required fields not specified, prompt for them too (use `lib/check-required.mjs`).
