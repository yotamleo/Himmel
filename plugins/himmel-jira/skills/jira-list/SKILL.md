---
name: jira-list
description: Use when user asks to list, show, or enumerate Jira issues (e.g. "what jira tickets are open", "list HIMMEL stories", "show me in-progress jira"). MUST mention "jira" or a project key (HIMMEL, LUNA, etc.) or an explicit ticket pattern. Do NOT trigger on "list PRs", "show issues" without context, or GitHub references.
---

Run `/jira-list [project] [status]` with the project and (optional) status the user mentioned. When no project is given, the CLI falls back to `JIRA_PROJECT_KEY`.
