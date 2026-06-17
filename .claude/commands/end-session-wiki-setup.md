---
description: Configure which Obsidian vault the end-session-wiki hook captures sessions into — writes LUNA_VAULT_PATH (global) or .claude/end-session-wiki.json vault_path (this repo only).
argument-hint: (none — interactive)
---

Point the `end-session-wiki` SessionEnd hook (`scripts/hooks/end-session-wiki.{sh,ps1}`) at the right Obsidian vault. The hook resolves its target vault by precedence: **per-repo `.claude/end-session-wiki.json` `vault_path` > global `LUNA_VAULT_PATH` env > default `~/Documents/luna`** (a leading `~/` is expanded). See [`docs/luna/end-session-wiki.md`](../../docs/luna/end-session-wiki.md) ("Choosing the target vault").

Run this from the **code repo** whose sessions you want captured. Be idempotent — re-running should update, not duplicate.

## Steps

1. **Ask for the vault path.** Prompt the user for the absolute path to the Obsidian vault that should receive session notes. Default: `~/Documents/luna`. Expand a leading `~/` to `$HOME` before validating. Validate the directory exists and contains a `.obsidian/` subdirectory (that's what makes it an Obsidian vault). If it doesn't, report the problem and stop — don't write a path that won't resolve.

2. **Ask for scope.**
   - **GLOBAL** — your default vault for every repo. Write `LUNA_VAULT_PATH=<path>` to the repo-root `.env`: if a `LUNA_VAULT_PATH=` line already exists (commented or not), replace it; otherwise append the line. Don't disturb other keys.
   - **THIS-REPO-ONLY** — route just this repo's sessions to that vault, overriding the global. Merge `"vault_path": "<path>"` into `.claude/end-session-wiki.json`, **preserving** any existing keys (`enabled`, `dry_run`, `min_duration_seconds`). Create the file with just `{ "vault_path": "<path>" }` if it doesn't exist. Use `jq` to merge so existing keys survive (e.g. `jq '. + {vault_path: $p}' --arg p "<path>"`).

3. **Confirm the REST API key is discoverable.** The hook delivers notes via the Obsidian Local REST API when a key is available, and falls back to writing on disk otherwise. Check whether either:
   - `OBSIDIAN_API_KEY` is set in the environment, OR
   - `<vault>/.obsidian/plugins/obsidian-local-rest-api/data.json` exists.

   If neither is found, warn the user that REST delivery won't work until they install/enable the Local REST API plugin and set `OBSIDIAN_API_KEY` — but note that the **on-disk fallback still captures notes without it** (Obsidian picks up file changes automatically).

4. **Report.** State exactly what you wrote (which file, which line/key) and the resulting precedence for this repo — i.e. which of `vault_path` / `LUNA_VAULT_PATH` / default now wins, and the absolute vault path sessions will land in.

Keep it tight. Ask the two questions, validate, write, confirm — nothing more.
