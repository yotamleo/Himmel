---
name: gh-pr-create
description: Use when user asks to open, create, or file a GitHub pull request ("open a PR", "create a pull request", "file a PR for this branch", "make a PR"). MUST mention PR / pull request. Do NOT trigger on "create issue" (could be ambiguous — could be GitHub issue or Jira). Do NOT trigger on Jira create ("create jira ticket" → himmel-jira).
---

# gh-pr-create

The user wants to open a new GitHub PR.

Before invoking `/gh-pr-create`:
1. Confirm the title and body with the user (PR creation is public/team-visible).
2. Build a `--title "..." --body "..."` invocation — do NOT call without those flags (the runner will hang on interactive prompts).
3. Run `/gh-pr-create --title "..." --body "..." [--base BRANCH] [--head BRANCH]` with the constructed args.

Output only the runner's one-line summary (typically the PR URL).
