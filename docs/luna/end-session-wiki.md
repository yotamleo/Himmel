# End-Session Wiki Hook — User Guide

Auto-captures every Claude Code session as a structured note in the Luna Obsidian vault. Built by epic #7 (tasks #24-#27). For the on-disk note shape, see [`end-session-wiki-schema.md`](./end-session-wiki-schema.md).

## Quickstart — multi-vault in 30 seconds

- **Default (zero config):** sessions capture into `~/Documents/luna`. Nothing to do.
- **One command:** run `/end-session-wiki-setup` from the code repo whose sessions you want captured — it walks the options and writes the config for you.
- **The four targeting options** (first match wins):
  1. **`vault_path`** — an absolute path, this repo only (machine-specific; don't commit on a shared repo).
  2. **`vault`** — a vault *name*, distributable and safe to commit; resolves per-machine via `~/.claude/luna-vaults.json`, else the `~/Documents/<name>` convention. **Recommended for shared repos.**
  3. **`LUNA_VAULT_PATH`** — an env var, your global default for every repo.
  4. **default** → `~/Documents/luna`.

The registry (`~/.claude/luna-vaults.json`) is **optional** — you only need it for a vault that doesn't live at `~/Documents/<name>`. Full detail + examples: [Choosing the target vault](#choosing-the-target-vault).

Your first capture in a vault is an *orphan* (no inbound links) until you build the index — run `scripts/sessions-reindex.sh` once afterward (see [Connecting notes into the graph](#connecting-notes-into-the-graph)).

## What it does

On every `SessionEnd` event, a hook runs `scripts/hooks/end-session-wiki.{ps1,sh}`. It reads the session transcript + git metadata, renders a session note matching the schema, and writes it into the Luna vault at `sessions/YYYY/MM/YYYY-MM-DD-HHMM-<repo>-<branch>.md`. The hook is silent on success and never blocks session end.

**Enabled by default.** It runs automatically on every session end — no setup is needed to start capturing, and a stock install writes into `~/Documents/luna`. Opt out per-session or per-repo (see [How to opt out](#how-to-opt-out)); sessions shorter than `min_duration_seconds` (default 60s) are skipped so accidental opens aren't captured.

**What the note contains.** Frontmatter (repo, branch, worktree, timestamps, `duration_minutes`, `files_touched`, tags) plus six fixed sections: Summary, Decisions, Files Touched, Commands, Follow-ups, Raw Conversation (full shape: [`end-session-wiki-schema.md`](./end-session-wiki-schema.md)). Two things to expect, so a sparse note doesn't read as a bug:

- Empty sections are written as `_None._` rather than dropped — the six-section shape is always present.
- `## Decisions` / `## Follow-ups` are **scaffolding** — only as complete as the transcript made parseable, so fill them in yourself when a session mattered; and `files_touched` counts the **working-tree diff over the session window**, so a session whose work was already committed (clean tree at session end) shows `0`. Neither is a failure.

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
| `vault_path` | string | `""` | Absolute path (a leading `~/` is expanded) to the Obsidian vault this repo's sessions are captured into. Empty → fall back to `vault`, then `LUNA_VAULT_PATH` env, then the default. See [Choosing the target vault](#choosing-the-target-vault) below. |
| `vault` | string | _(absent)_ | Vault **name** (not a path) — e.g. `"luna-medic"`. Distributable/safe to commit; resolved to a path per-machine (registry, then the `~/Documents/<name>` convention). An invalid or unresolvable name **skips** the capture rather than misrouting it. See [Choosing the target vault](#choosing-the-target-vault). |

Missing file → defaults applied (`enabled: true`, `dry_run: false`, `min_duration_seconds: 60`); `vault_path`/`vault` absent.

> **Write this file as UTF-8 _without_ a BOM.** A leading byte-order mark makes the hook treat the config as invalid JSON and **fail closed — it silently stops capturing** (HIMMEL-408). On Windows, PowerShell 5.1's `Set-Content -Encoding utf8` _adds_ a BOM; use `-Encoding utf8NoBOM` (PowerShell 7+) or an editor that omits it. `/end-session-wiki-setup` and hand-edits in most editors are fine.

## Choosing the target vault

Your vault almost certainly does not live where the operator's does, and you may keep more than one (e.g. a general vault plus a project-specific one). The hook resolves the target vault in this order — **first match wins**:

1. **`vault_path` in `.claude/end-session-wiki.json`** (per-repo, absolute path) — the most specific, highest priority. An absolute path is machine-specific, so prefer `vault` (below) for anything you commit and share.
2. **`vault` name in `.claude/end-session-wiki.json`** (per-repo, **distributable**) — a vault *name* instead of a path, so the same committed config works on every machine. Resolved per-machine: first the operator registry `~/.claude/luna-vaults.json`, else the convention `~/Documents/<name>`. The convention target must be a real vault (contain an `.obsidian/` folder); a name that resolves to no real vault — or fails validation (1–64 chars, must match `[A-Za-z0-9._-]`, start alphanumeric, no `/` or `..`) — **skips the capture rather than misrouting it** (logged as `skipped: vault …`). A config file that exists but is **not valid JSON** also skips (fail-closed) rather than falling through to the default, so a malformed config can't silently leak a sensitive repo's sessions into the general vault.
3. **`LUNA_VAULT_PATH` environment variable** (global) — your default vault for everything that doesn't override it per-repo. Set it in your shell profile or your `.env` (see `.env.example`).
4. **Built-in default** — the `luna` vault: the `luna` entry in `~/.claude/luna-vaults.json` if you have one, else `~/Documents/luna` (`$HOME`/`$USERPROFILE`), so a stock install still works with zero config.

`vault_path` configures a path (renaming/moving the vault means updating that path). `vault` configures a name and each machine resolves the path — so the same committed value works everywhere: an operator either follows the `~/Documents/<name>` convention (zero extra config) or maps the name in their registry.

**Set the target interactively** with the `/end-session-wiki-setup` command — run it from your code repo and it writes the value for you (any of the options above). The luna template setup (`templates/luna-second-brain/scripts/setup.{sh,ps1}`) prints the same options after a fresh install but doesn't write them. Or configure by hand:

```json
// .claude/end-session-wiki.json — capture THIS repo's sessions into a specific vault (absolute path)
{ "vault_path": "~/Documents/my-vault" }
```

```json
// .claude/end-session-wiki.json — distributable: route by vault NAME (safe to commit)
{ "vault": "luna-medic" }
```

```json
// ~/.claude/luna-vaults.json — per-machine name→path map (optional;
// only needed for vaults that don't live at ~/Documents/<name>)
{ "vaults": { "luna-medic": "~/Documents/luna-medic" } }
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

Notes live under `<luna-vault>/sessions/YYYY/MM/`. Default vault root: `$HOME/Documents/luna`, overridable per-repo with `vault_path` or `vault` in `.claude/end-session-wiki.json`, or globally with `LUNA_VAULT_PATH` (see [Choosing the target vault](#choosing-the-target-vault)).

Search across captured sessions via the Obsidian MCP:

```
mcp__obsidian-vault__obsidian_simple_search query:"end-session-wiki"
```

Or filter by branch in the file path: `sessions/2026/05/2026-05-18-*-feat-end-session-wiki-*.md`.

## Connecting notes into the graph

The hook files each note but does not maintain an index, so a fresh capture is an *orphan* (no inbound links) and its `[[<repo>]]` preamble link dangles until a hub note exists. Run `scripts/sessions-reindex.sh` to fix both, idempotently:

```bash
bash scripts/sessions-reindex.sh                       # default ~/Documents/luna
bash scripts/sessions-reindex.sh --vault ~/Documents/luna-medic
```

It regenerates `<vault>/sessions/_index.md` (links every session note → no orphans) and creates a `sessions/<repo>.md` hub for each repo that doesn't already resolve `[[<repo>]]` somewhere in the vault. Lean-invoke: run on demand after a batch of captures (or wire it into the clip-pipeline cadence).

## Disabling per-session

One-shot disable for a single Claude run, no config edit needed:

```powershell
$env:CLAUDE_END_SESSION_WIKI = "0"; claude
```

```bash
CLAUDE_END_SESSION_WIKI=0 claude
```

The env var takes precedence over the config file — useful for throwaway exploration sessions or when you want to verify the hook's no-op path without editing repo state.
