---
name: gh-init
description: Use ONLY when user explicitly asks to bootstrap, set up, initialize, or verify GitHub CLI authentication. Triggers on phrases like "set up gh", "init gh", "check gh auth", "verify github login", "is gh logged in". Do NOT trigger on routine GitHub PR ops (view/list/create/checks) — those have their own skills. Do NOT trigger on Jira setup (HIMMEL-N format or "jira" → himmel-jira plugin).
---

# gh-init

The user wants to verify the gh CLI is authenticated with the right scopes (or wants instructions to log in).

Run `/gh-init`. Output the single one-line summary the slash command prints. If it exits non-zero with `gh NOT logged in`, tell the user to run `gh auth login --web` from their own terminal — that flow is interactive (browser) and cannot be automated.
