# End-Session Wiki Hook — User Guide

Auto-captures every Claude Code session as a structured note in the Luna Obsidian vault. Built by epic #7 (tasks #24-#27). For the on-disk note shape, see [`end-session-wiki-schema.md`](./end-session-wiki-schema.md).

## What it does

On every `SessionEnd` event, a hook runs `scripts/hooks/end-session-wiki.{ps1,sh}`. It reads the session transcript + git metadata, renders a session note matching the schema, and writes it into the Luna vault at `sessions/YYYY/MM/YYYY-MM-DD-HHMM-<repo>-<branch>.md`. The hook is silent on success and never blocks session end.

The note is delivered via the Obsidian Local REST API when an API key is available. If no key is found, or the REST PUT fails (e.g. Obsidian isn't running), the hook falls back to writing the note directly to the vault on disk — Obsidian picks up on-disk changes automatically, so capture works whether or not the plugin is up.

## Security note — log files contain raw transcript text

The hook writes diagnostic output to `.claude/end-session-wiki.log` and (during dry-run mode) the full rendered note including the `## Raw Conversation` callout that quotes the tail of your session transcript. Anything you typed into Claude — pasted credentials, API keys, secrets — can appear verbatim in those logs.

These files are gitignored by default. Do not commit them. If you copy them off-disk for debugging, redact secrets first.

## How to opt out

Two equivalent controls — pick whichever matches your scope.

**Env var (per-shell or per-session):**

```powershell
# Disable for this Claude Code session only:
$env:CLAUDE_END_SESSION_WIKI = "0"
claude
```

```bash
# Disable for a one-off run:
CLAUDE_END_SESSION_WIKI=0 claude
```

Accepted off-values (case-insensitive): `0`, `false`. Anything else (including unset) leaves the hook enabled.

**Repo config (persistent, per-repo):**

Edit `.claude/end-session-wiki.json`:

```json
{
  "enabled": false,
  "dry_run": false,
  "min_duration_seconds": 60
}
```

Fields:

| Field | Type | Default | Effect |
|-------|------|---------|--------|
| `enabled` | bool | `true` | `false` → hook exits 0 after logging `skipped: config disabled` |
| `dry_run` | bool | `false` | `true` → render note to log file instead of writing to vault |
| `min_duration_seconds` | int | `60` | Sessions shorter than this are skipped (prevents capturing accidental opens) |
| `vault_path` | string | `""` | Absolute path (a leading `~/` is expanded) to the Obsidian vault this repo's sessions are captured into. Empty → fall back to `LUNA_VAULT_PATH` env, then the default. See [Choosing the target vault](#choosing-the-target-vault) below. |

Missing file → defaults applied (`enabled: true`, `dry_run: false`, `min_duration_seconds: 60`, `vault_path: ""`).

## Choosing the target vault

Your vault almost certainly does not live where the operator's does, and you may keep more than one (e.g. a general vault plus a project-specific one). The hook resolves the target vault in this order — **first match wins**:

1. **`vault_path` in `.claude/end-session-wiki.json`** (per-repo) — the most specific. Set this in a repo (or a multi-repo's shared config) to route *that* repo's sessions to a particular vault, regardless of the global default. This is what lets, say, a medical-notes repo capture into a separate vault from your day-to-day work.
2. **`LUNA_VAULT_PATH` environment variable** (global) — your default vault for everything that doesn't override it per-repo. Set it in your shell profile or your `.env` (see `.env.example`).
3. **Built-in default** — `~/Documents/luna` (`$HOME`/`$USERPROFILE`), so a stock install still works with zero config.

Because the path is what you configure (not a vault *name*), **renaming or moving the vault just means updating the path** in step 1 or 2 — nothing else references the old location.

**Set it interactively** with the luna template setup (`templates/luna-second-brain/scripts/setup.{sh,ps1}`) or the `/end-session-wiki-setup` command, which write the value for you. Or set it by hand:

```json
// .claude/end-session-wiki.json — capture THIS repo's sessions into a specific vault
{ "vault_path": "~/Documents/my-vault" }
```

```bash
# .env or shell profile — global default vault for all repos
LUNA_VAULT_PATH="$HOME/Documents/my-vault"
```

## Logs

Path: `.claude/end-session-wiki.log` (repo-local).

Every hook invocation appends one line: `[<UTC-ISO timestamp>] <message>`. Messages include `wrote <path> (<ms>ms)`, `skipped: <reason>`, and `ERROR: <detail>` (for failed vault writes). In dry-run mode, the full rendered markdown is appended between `===` separators so you can inspect the exact note that would have been written.

**Rotation:** when the log exceeds 1 MB, it is renamed to `.claude/end-session-wiki.log.old` (overwriting any prior `.log.old`) and a fresh log begins on the next write. Only the two most recent files (`.log` + `.log.old`) are retained.

## Inspecting captured notes

Notes live under `<luna-vault>/sessions/YYYY/MM/`. Default vault root: `$HOME/Documents/luna` (override with `LUNA_VAULT_PATH`).

Search across captured sessions via the Obsidian MCP:

```
mcp__obsidian-vault__obsidian_simple_search query:"end-session-wiki"
```

Or filter by branch in the file path: `sessions/2026/05/2026-05-18-*-feat-end-session-wiki-*.md`.

## Disabling per-session

One-shot disable for a single Claude run, no config edit needed:

```powershell
$env:CLAUDE_END_SESSION_WIKI = "0"; claude
```

```bash
CLAUDE_END_SESSION_WIKI=0 claude
```

The env var takes precedence over the config file — useful for throwaway exploration sessions or when you want to verify the hook's no-op path without editing repo state.
