---
allowed-tools: Bash(himmel-run:*), Bash(node:*)
description: Create a Jira issue. Returns one-line summary with new KEY. Supports --attach <path> (repeatable) for screenshots/logs.
argument-hint: "<type> \"<title>\" [--parent KEY] [--desc \"...\"] [--attach path]..."
---

> **Note (Windows):** the body uses bash parameter expansion / subshell syntax. Claude Code's `Bash` tool invokes Git Bash on Windows — works as long as Git Bash is on PATH (which it is when this repo's `setup/win11.ps1` ran successfully).

## Your task

Resolve required fields for the type from the metadata cache (no `--project` —
it resolves to the cache's `default_project`, set from your `JIRA_PROJECT_KEY`):

```
node $CLAUDE_PROJECT_DIR/plugins/himmel-jira/lib/check-required.mjs --type "$1"
```

If any required field is missing from the user's command, ask the user to supply it via AskUserQuestion. Then (note the regex now also matches the `(attachments: N)` suffix):

```
himmel-run jira \
  --summary-regex '^Created ([A-Z]+-\d+)' \
  --on-stderr-match 'field .* is required' \
  --then-cmd-json '["node","'"$CLAUDE_PROJECT_DIR"'/plugins/himmel-jira/lib/init-cli.mjs","--discover"]' \
  -- node $CLAUDE_PROJECT_DIR/scripts/jira/dist/index.js create --type "$1" --title "$2" "${@:3}"
```

Pass `--attach <path>` (repeatable) through after `$2`. The CLI uploads each file after issue creation and prints `Created KEY (attachments: N)`.
