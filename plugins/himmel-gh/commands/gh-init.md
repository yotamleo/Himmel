---
allowed-tools: Bash(node:*)
description: "Verify forge auth (gh scopes on GitHub, BITBUCKET_EMAIL/API_TOKEN on Bitbucket). Prints one-line summary; exit 1 if not authenticated. Run once per machine."
---

## Your task

Run exactly:

```
node $CLAUDE_PROJECT_DIR/plugins/himmel-gh/lib/init-cli.mjs
```

It detects the forge from the `origin` remote (defaulting to GitHub). On a
GitHub repo it verifies `gh` auth + OAuth scopes; on a Bitbucket repo it checks
the himmel `bitbucket` CLI auth (`BITBUCKET_EMAIL` + `BITBUCKET_API_TOKEN`)
instead of `gh` scopes.

Output the single one-line summary the command prints. Do NOT add commentary.

If it exits non-zero with `gh NOT logged in`, tell the user to run
`gh auth login --web` from their own terminal (interactive browser flow; not
automatable via Claude). If it exits non-zero with `bitbucket NOT authenticated`,
tell the user to set `BITBUCKET_EMAIL` + `BITBUCKET_API_TOKEN` in their environment.
