---
template_version: 2
jira: <KEY>
bucket: next
priority: Medium
severity: —
created: <UTC-ISO-8601>
updated: <UTC-ISO-8601>
pending_jira_link: false
---
# Epic #N Context — <Name>

> Subagent entry point. Keep ≤1 page. Do not expand.

## What This Is

[2-3 sentences. What problem, why it matters.]

## Current State

- Done: ...
- Active: #N <task-slug>
- Pending: #N <task-slug>, #N <task-slug>

## Key Paths / Constraints

- Repo: `<repo-name>` (root: `<repo-root>`)
- State root: `<state-root>`
- Key files: ...
- Rules: ...

## Subagent Dispatch

To work on a task, load:
1. This file (`context.md`) — epic lean context
2. `tasks/#N-<slug>/brief.md` — task-specific spec
