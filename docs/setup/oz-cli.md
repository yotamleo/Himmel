# Oz CLI (local Warp usage)

Warp's `oz` is a cloud-agent orchestration CLI ("running, managing, and orchestrating coding agents at scale"). This doc covers using `oz` **directly from a local Warp terminal**, not from inside a Claude Code session.

> Status: low priority. Doc-only. No wrapper scripts, hooks, or CI integration.

---

## Auth Bootstrap

### Binary location (Windows)

`oz` is shipped as part of the Warp install. Invoke it one of two ways:

```powershell
# Direct, with CLI-mode env var
$env:WARP_CLI_MODE = "1"
& "$env:LOCALAPPDATA\Programs\Warp\warp.exe" --help

# Or via the shipped wrapper (sets WARP_CLI_MODE=1 for you)
& "$env:LOCALAPPDATA\Programs\Warp\bin\oz.cmd" --help
```

If the wrapper isn't on `PATH`, add `%LOCALAPPDATA%\Programs\Warp\bin` to your user `PATH` and just run `oz`.

### One-time login (interactive)

```powershell
oz login
```

Opens a browser to authenticate against your Warp account. Token is cached locally.

### Non-interactive auth

For headless / scripted use, set:

```powershell
$env:WARP_API_KEY = "<your-api-key>"
```

Generate the key from the Warp web dashboard. Prefer this over `oz login` when running from a scheduled task or non-TTY shell.

---

## Command Cheatsheet

| Command | One-liner | Example |
|---------|-----------|---------|
| `oz agent` | Manage cloud agents | `oz agent list` |
| `oz run` | Kick off a one-shot agent task | `oz run "refactor the auth module and open a PR"` |
| `oz schedule` | Schedule recurring agent runs (cron) | `oz schedule create --cron "0 9 * * *" "daily repo health check"` |
| `oz secret` | Manage secrets exposed to agents | `oz secret set GITHUB_TOKEN <value>` |
| `oz environment` | Manage env vars / configs for agent runs | `oz environment set --name prod KEY=value` |

Run `oz <command> --help` for full flags. The shape of subcommands may drift — treat this table as a starting point, not an exhaustive spec.

---

## When to Use Oz vs Not

**Use Oz** when:
- The task is long-running and independent (research, scheduled background work, multi-step refactors that benefit from their own compute).
- You want to drive it from a Warp tab and walk away.
- It needs to run on a cron / schedule with no human in the loop.

**Use an in-session Claude subagent** when:
- The task needs context from the current Claude Code session.
- It finishes in a few minutes.
- The output should land back in your active conversation.

**Use a plain Warp tab (no Oz)** when:
- It needs human supervision: dev server, log tail, interactive REPL.
- You want immediate stdout, not an async agent result.

---

## LOCAL offload via `/oz-offload`

Inline Claude (a running Claude Code session) can offload long-running independent
tasks to a **separate local Warp terminal tab** that runs `warp agent run`. Same
machine only, fire-and-forget, no cloud agents.

```text
/oz-offload "summarize the architecture of this repo and post findings to PR #34"
```

This invokes `scripts/oz/offload.ps1`, which:

1. Writes the prompt to a tempfile under `%TEMP%\oz-offload\`.
2. Writes a one-shot PowerShell launcher that reads the prompt and invokes
   `warp.exe agent run --prompt <text>`.
3. Writes a Warp Launch Configuration YAML to
   `%APPDATA%\warp\Warp\data\launch_configurations\oz-offload-<ts>-<uuid>.yaml`
   that runs the launcher in a new tab with `cwd:` set to the current repo.
4. Fires `warp://launch/<name>` via `Start-Process` so this Claude session
   returns immediately.
5. Prunes any `oz-offload-*` configs and tempfiles older than 72h.

### Constraints

- **Windows-only** (operator's box). macOS/Linux paths differ — file a follow-up
  if needed.
- **Fire-and-forget** in v1 — no PID, no exit code, no result captured back.
  Inspect progress in the Warp tab directly. `warp agent run` surfaces a
  `Run ID: <uuid>` and an `Open in Oz: https://oz.warp.dev/runs/<id>` URL
  in the new tab; v2 will capture those so a follow-up command (e.g.
  `/oz-resume <id>`) can continue the conversation via
  `warp agent run --conversation <id>`.
- **Same-machine only** — won't work in CI, won't work over SSH.
- **Tab cleanup** — the launcher appends `exit` after `warp agent run` returns,
  so Warp closes the tab automatically *if* "Close tab on shell exit" is
  enabled in Warp settings. With that setting off, tabs stay open and accumulate
  — close them manually.
- **Legacy API risk** — uses Warp Launch Configurations (legacy, replaced by
  Tab Configs which are UI-only and cannot be launched programmatically
  per upstream FRs warpdotdev/Warp#9060 and #9083). If Warp drops Launch
  Configurations, this breaks. Pin Warp version if you depend on this.
- **Offload target is `warp agent run`** (Warp's native local agent),
  *not* `claude -p`. `claude -p` is not in normal usage.
- **Not free — consumes Warp credits.** `warp agent run` (local) bills
  against the same Warp credit pool as cloud agents. Failed runs show
  `Status: Your team has run out of credits. Purchase more credits to continue.`
  in `warp run list`. Use `/oz-offload` only when the credit cost is worth
  it relative to the Claude Code session-budget saving.

### When NOT to use `/oz-offload`

Same rules as the "Use an in-session Claude subagent" column below — if the
task needs current-session context, finishes in seconds, is interactive, or
needs its result delivered back into this conversation, `/oz-offload` is wrong.

---

## NOT in scope

This doc covers **local** Warp + Oz usage only. The following are **explicitly out of scope**:

- Cloud Oz agents (`oz agent run-cloud`) — superseded by the local `/oz-offload` path.
- Anthropic API key as an Oz secret, `WARP_API_KEY` in env, Oz environments.
- Pre-commit hooks, CI workflows, or repo-level `oz` cloud integration.
- A `claude -p`-based offload (explicitly not in normal usage).

The operator runs `oz` directly in their own Warp terminal for cloud work,
or uses `/oz-offload` from inside Claude Code for local dispatch.
If those constraints change, file a new task — don't extend this doc.

---

## References

- Warp docs root: https://docs.warp.dev/ (find the Oz / Agents section from the sidebar)
- `oz --help` from a local Warp terminal is the source of truth for the current command surface.
