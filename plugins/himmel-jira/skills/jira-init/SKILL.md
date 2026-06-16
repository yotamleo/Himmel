---
name: jira-init
description: Use ONLY when user explicitly asks to bootstrap, set up, or initialize Jira authentication and metadata cache. Triggers on phrases like "set up jira", "init jira", "bootstrap jira plugin", "configure jira". Do NOT trigger on routine jira ops (create/list/transition) — those have their own skills. Do NOT trigger on PR or GitHub setup (those go to himmel-gh).
---

# jira-init

The user wants to bootstrap the himmel-jira plugin (auth + metadata cache).

Tell them to run `/jira-init` (slash command — requires interactive prompts). The skill cannot prompt for secrets; the slash command can.
