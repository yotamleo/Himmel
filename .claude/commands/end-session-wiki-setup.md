---
description: Configure which Obsidian vault the end-session-wiki hook captures sessions into — by vault NAME (distributable, HIMMEL-403), an absolute vault_path, or the global LUNA_VAULT_PATH.
argument-hint: (none — interactive)
---

Point the `end-session-wiki` SessionEnd hook (`scripts/hooks/end-session-wiki.{sh,ps1}`) at the right Obsidian vault. The hook resolves its target vault by precedence (**first match wins**):

1. per-repo `.claude/end-session-wiki.json` **`vault_path`** (absolute)
2. per-repo `.claude/end-session-wiki.json` **`vault`** NAME → operator registry `~/.claude/luna-vaults.json` → else convention `~/Documents/<name>` (must contain an `.obsidian/` marker)
3. global **`LUNA_VAULT_PATH`** env
4. default — the `luna` entry in `~/.claude/luna-vaults.json` if present, else **`~/Documents/luna`**

A leading `~/` is expanded. An invalid/unresolvable `vault` name, or a config that isn't a valid JSON object, **fails closed** (skips the capture, never misroutes). Full options + examples: [`docs/luna/end-session-wiki.md`](../../docs/luna/end-session-wiki.md) ("Choosing the target vault").

Run this from the **code repo** whose sessions you want captured. Be idempotent — re-running should update, not duplicate.

## Steps

1. **Ask how to target the vault** — three choices:
   - **BY-NAME (recommended, distributable)** — best when the config is committed/shared (the same repo on another machine still works). You configure a *name*; each machine resolves it to a path. Go to step 2a.
   - **BY-PATH (this repo, absolute)** — a concrete absolute path for *this* repo only. Machine-specific, so don't commit it if the repo is shared. Go to step 2b.
   - **GLOBAL (every repo)** — your default vault for all repos via `LUNA_VAULT_PATH`. Go to step 2c.

2a. **By name.**
   - Ask for the **vault name** (e.g. `salus`). Validate: 1–64 chars, `[A-Za-z0-9._-]`, must start alphanumeric, no `/` or `..`. Reject otherwise.
   - Resolve the name to a path: if `~/Documents/<name>/.obsidian/` exists, that's the convention target — **no registry entry needed**. Otherwise ask for the absolute vault path (or `~/`-prefixed) and write the mapping into `~/.claude/luna-vaults.json`, preserving existing entries:
     `jq '.vaults = ((.vaults // {}) + {($n): $p})' --arg n "<name>" --arg p "<path>"` (create the file as `{ "vaults": { "<name>": "<path>" } }` if absent). The path should contain an `.obsidian/` marker.
   - Merge `"vault": "<name>"` into this repo's `.claude/end-session-wiki.json`, preserving existing keys: `jq '. + {vault: $n}' --arg n "<name>"`. Create as `{ "vault": "<name>" }` if absent.

2b. **By path (this repo only).** Ask for the absolute path (default `~/Documents/luna`); expand a leading `~/`; validate the dir exists and contains `.obsidian/` — if not, report and stop. Merge `"vault_path": "<path>"` into `.claude/end-session-wiki.json`, preserving existing keys: `jq '. + {vault_path: $p}' --arg p "<path>"`. Create as `{ "vault_path": "<path>" }` if absent.

2c. **Global.** Ask for the absolute path (default `~/Documents/luna`); expand + validate as in 2b. Write `LUNA_VAULT_PATH=<path>` to the repo-root `.env`: replace an existing `LUNA_VAULT_PATH=` line (commented or not) or append. Don't disturb other keys.

3. **Confirm the REST API key is discoverable.** The hook delivers notes via the Obsidian Local REST API when a key is available, and falls back to writing on disk otherwise. Check whether either:
   - `OBSIDIAN_API_KEY` is set in the environment, OR
   - `<vault>/.obsidian/plugins/obsidian-local-rest-api/data.json` exists.

   If neither is found, warn that REST delivery won't work until they install/enable the Local REST API plugin and set `OBSIDIAN_API_KEY` — but note the **on-disk fallback still captures notes without it** (Obsidian picks up file changes automatically).

4. **Report.** State exactly what you wrote (which file, which key/line), which precedence tier now wins for this repo, and the absolute vault path sessions will land in. For BY-NAME, show both the repo `vault` key and how the name resolved (registry entry or `~/Documents/<name>` convention).

Keep it tight. Ask the targeting question, validate, write, confirm — nothing more.
