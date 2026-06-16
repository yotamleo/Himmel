---
name: jira-get
description: Use when user asks to show, view, or look up a single Jira issue by key (e.g. "show me HIMMEL-46", "what does HIMMEL-99 say", "get LUNA-3"). MUST contain an explicit Jira key matching [A-Z]+-\d+. Do NOT trigger on PR numbers (#123) or GitHub issue references.
---

Run `/jira-get <KEY>` with the exact key the user mentioned.
