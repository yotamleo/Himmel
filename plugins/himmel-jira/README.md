# himmel-jira

Thin Claude Code plugin wrapping `scripts/jira/` CLI through `scripts/himmel-run/`.

## Install

The plugin lives in this repo. Add via:

```
/plugin install ./plugins/himmel-jira
```

## Auth file location

`/jira-init` writes `JIRA_EMAIL`, `JIRA_API_TOKEN`, and `JIRA_BASE_URL` to (all three are required):

- **POSIX:** `<repo-root>/.env` if that `.env` file already exists at the repo root; otherwise `~/.config/himmel-cli/jira.env`.
- **Windows:** same code path as POSIX — `<repo-root>/.env` if that file exists at repo root; otherwise `%USERPROFILE%\.config\himmel-cli\jira.env`. (Metadata cache is separate: `%LOCALAPPDATA%\himmel-cli\jira\`.)

The file is `chmod 600` on POSIX. On Windows, access is governed by the parent directory ACL.

## Commands

- `/jira-init` — bootstrap auth + metadata cache (run once per machine).
- `/jira-list [project] [status]` — list issues.
- `/jira-get <KEY>` — show one issue.
- `/jira-create <type> "<title>"` — file issue.
- `/jira-transition <KEY> <status>` — transition issue.
- `/jira-comment <KEY> "<body>"` — add comment.
- `/jira-refresh` — re-fetch metadata cache.

Each command has a matching skill that auto-triggers on Jira intent.

## Logs

Cache + logs at `~/.cache/himmel-cli/jira/` (POSIX) or `%LOCALAPPDATA%/himmel-cli/jira/` (Windows). Inspect any run:

```
himmel-run jira --inspect <run-id-from-summary-line>
```
