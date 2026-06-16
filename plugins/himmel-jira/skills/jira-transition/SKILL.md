---
name: jira-transition
description: Use when user asks to move, transition, or change the status of a Jira issue (e.g. "move HIMMEL-46 to In Progress", "transition HIMMEL-99 to Done", "mark HIMMEL-12 as Blocked"). MUST contain an explicit Jira key and a target status name. Do NOT trigger on PR status changes or GitHub issue closures.
---

Run `/jira-transition <KEY> <status>` with the key and target status from the user's message. The slash command resolves the transition ID from the metadata cache.
