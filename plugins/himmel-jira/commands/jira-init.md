---
allowed-tools: Bash(node:*), AskUserQuestion
description: "Bootstrap Jira auth (.env) + metadata cache (~/.cache/himmel-cli/jira/metadata.json (POSIX) / %LOCALAPPDATA%\\himmel-cli\\jira\\metadata.json (Windows)). Run once per machine."
---

## Context

- Current `.env` keys (existence only): !`node $CLAUDE_PROJECT_DIR/plugins/himmel-jira/lib/check-env.mjs 2>&1 || true`

## Your task

1. Run `node plugins/himmel-jira/lib/init-cli.mjs --check`.
   - If it prints `needs-prompt: ...`, use AskUserQuestion to collect each missing value. The three required keys are:
     - `JIRA_EMAIL` — your Atlassian account email address.
     - `JIRA_API_TOKEN` — your Atlassian API token (do NOT echo back to the user).
     - `JIRA_BASE_URL` — your Jira cloud base URL, e.g. `https://<your-org>.atlassian.net` (no trailing slash).
   - Then run `node plugins/himmel-jira/lib/init-cli.mjs --write-env --email <e> --token <t> --base-url <url>` with whichever flags correspond to missing keys.
2. Re-run `node plugins/himmel-jira/lib/init-cli.mjs --discover`. This discovers the project(s) from `JIRA_PROJECT_KEY` (or `JIRA_PROJECTS=A,B` in `.env` to cache several) and writes the metadata cache. If no project is configured it exits 2 with a hint — set the key and re-run.
3. Output the single one-line summary the command prints. Do NOT add commentary.
