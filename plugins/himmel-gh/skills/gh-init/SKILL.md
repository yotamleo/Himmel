---
name: gh-init
description: Bootstrap/verify GitHub CLI auth ("set up gh", "check gh auth", "is gh logged in"). Not PR ops or Jira setup.
---

# gh-init

The user wants to verify forge auth (or wants instructions to log in).

Run `/gh-init`. It detects the forge from the `origin` remote (defaulting to GitHub): on a GitHub repo it verifies `gh` auth + scopes; on a Bitbucket repo it checks the himmel `bitbucket` CLI auth (`BITBUCKET_EMAIL` + `BITBUCKET_API_TOKEN`) instead of `gh` OAuth scopes.

Output the single one-line summary the slash command prints. If it exits non-zero with `gh NOT logged in`, tell the user to run `gh auth login --web` from their own terminal — that flow is interactive (browser) and cannot be automated. If it exits non-zero with `bitbucket NOT authenticated`, tell the user to set `BITBUCKET_EMAIL` + `BITBUCKET_API_TOKEN`.
