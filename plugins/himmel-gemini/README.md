# himmel-gemini

Thin Claude Code plugin wrapping [gemini-cli](https://github.com/google-gemini/gemini-cli)
through the shared chokepoint `scripts/gemini/invoke.sh`. Story A of the
gemini-cli integration (HIMMEL-158).

## Install

The plugin lives in this repo. Add via:

```
/plugin install ./plugins/himmel-gemini
```

## Prerequisites

- gemini-cli installed and on PATH.
- Auth configured (OAuth web login by default — `~/.gemini/oauth_creds.json`).
  `invoke.sh` defers entirely to gemini-cli for auth; no API key required for
  the OAuth free tier. See `invoke.sh` for the `GEMINI_API_KEY` /
  `GOOGLE_API_KEY` / force-flag precedence.

## Commands

- `/gemini <prompt> [--model <name>] [--json] [--yolo]` — run gemini-cli
  synchronously and return its stdout. Thin wrapper around `invoke.sh`.
- `/gemini-bg <prompt>` — dispatch gemini-cli in a background Warp tab
  (fire-and-forget). Returns the log path immediately; output lands under
  `<repo-top>/logs/gemini/<UTC-ts>-<slug>.log`. Forked from the `oz-offload`
  two-file Warp launcher (`scripts/gemini/offload-bg.ps1`).

There is also a `gemini-subagent` Agent (`.claude/agents/gemini-subagent.md`)
that triggers on phrases like "delegate to gemini", "second opinion",
"large-context read", and "parallel triage". It calls the same chokepoint and
returns gemini stdout.

## Chokepoint

All entrypoints funnel through `scripts/gemini/invoke.sh`:

```
bash scripts/gemini/invoke.sh [--model <name>] [--cwd <path>] [--json] [--yolo] [--log <path>] [<prompt>|-]
```

`-` or an omitted prompt reads from stdin. No retries; exits with gemini-cli's
return code. Smoke test: `bash scripts/gemini/test-invoke.sh` (skips cleanly
when gemini is absent).
