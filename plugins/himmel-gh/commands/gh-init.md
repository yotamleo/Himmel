---
allowed-tools: Bash(node:*)
description: "Verify gh auth + scopes. Prints one-line summary; exit 1 with `gh auth login --web` instructions if not authenticated. Run once per machine."
---

## Your task

Run exactly:

```
node $CLAUDE_PROJECT_DIR/plugins/himmel-gh/lib/init-cli.mjs
```

Output the single one-line summary the command prints. Do NOT add commentary.

If the command exits non-zero with `gh NOT logged in`, tell the user to run `gh auth login --web` from their own terminal (interactive browser flow; not automatable via Claude).
