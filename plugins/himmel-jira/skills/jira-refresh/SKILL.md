---
name: jira-refresh
description: Use when user asks to refresh, update, or re-fetch the Jira metadata cache (e.g. "refresh jira metadata", "re-fetch jira projects", "jira cache is stale"). Also use when a /jira-create command hints the cache is out of date.
---

Run `/jira-refresh`. It re-fetches projects, issue types, and transitions into `~/.cache/himmel-cli/jira/metadata.json`.
