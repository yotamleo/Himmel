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
- Auth configured. **As of 2026-06-18 Google sunset "Login with Google"
  (OAuth) for Gemini CLI on consumer tiers — free *and* Google AI Pro/Ultra**;
  the old `~/.gemini/oauth_creds.json` web-login path no longer serves those
  accounts. gemini-cli now needs either an **API key** (`GEMINI_API_KEY` from
  Google AI Studio, or `GOOGLE_API_KEY` for Vertex AI) or a paid **Gemini Code
  Assist Standard/Enterprise** account. `invoke.sh` defers entirely to
  gemini-cli for auth — it reads no credentials itself; see `invoke.sh` for the
  `GEMINI_API_KEY` / `GOOGLE_API_KEY` / force-flag precedence.

## Commands

- `/gemini <prompt> [--model <name>] [--json] [--yolo]` — run gemini-cli
  synchronously and return its stdout. Thin wrapper around `invoke.sh`.

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
