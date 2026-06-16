---
name: jira-create
description: Use when user asks to file, create, open, or log a new Jira ticket (e.g. "file a jira for X", "create a bug ticket", "open a story"). MUST mention "jira", "ticket", "story", "bug", or "epic" together with create-intent verb. Do NOT trigger on "open a PR" or "file a bug report on GitHub".
---

Use the `/jira-create` slash command. Parse the user's request for type (Story/Bug/Task/Epic) and title; ask via AskUserQuestion if either is unclear. If type has required fields not specified, prompt for them too (use `lib/check-required.mjs`).
