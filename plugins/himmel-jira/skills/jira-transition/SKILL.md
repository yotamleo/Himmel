---
name: jira-transition
description: Move/transition a Jira issue status ("move HIMMEL-46 to In Progress"). Needs key + target status. Not PR status changes.
---

Run `/jira-transition <KEY> <status>` with the key and target status from the user's message. The slash command resolves the transition ID from the metadata cache.
