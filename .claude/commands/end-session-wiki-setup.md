---
description: Configure which Obsidian vault the end-session-wiki hook captures sessions into — by name, path, or LUNA_VAULT_PATH.
argument-hint: (none — interactive)
---

Point the `end-session-wiki` SessionEnd hook (`scripts/hooks/end-session-wiki.{sh,ps1}`) at the right Obsidian vault. The hook resolves its target vault by precedence (**first match wins**):

1. per-repo `.claude/end-session-wiki.json` **`vault_path`** (absolute)
2. per-repo `.claude/end-session-wiki.json` **`vault`** NAME → operator registry `~/.claude/luna-vaults.json` → else convention `~/Documents/<name>` (must contain an `.obsidian/` marker)
3. global **`LUNA_VAULT_PATH`** env — read from the **live process environment**, so it must come from `~/.claude/settings.json`'s `env` block or your shell profile. The repo-root `.env` is **not** bridged for this hook; a value written there is never seen.
4. default — the `luna` entry in `~/.claude/luna-vaults.json` if present, else **`~/Documents/luna`**

A leading `~/` is expanded. An invalid/unresolvable `vault` name, or a config that isn't a valid JSON object, **fails closed** (skips the capture, never misroutes). Full options + examples: [`docs/luna/end-session-wiki.md`](../../docs/luna/end-session-wiki.md) ("Choosing the target vault").

Run this from the **code repo** whose sessions you want captured. Be idempotent — re-running should update, not duplicate.

## Steps

1. **Ask how to target the vault** — three choices:
   - **BY-NAME (recommended, distributable)** — best when the config is committed/shared (the same repo on another machine still works). You configure a *name*; each machine resolves it to a path. Go to step 2a.
   - **BY-PATH (this repo, absolute)** — a concrete absolute path for *this* repo only. Machine-specific, so don't commit it if the repo is shared. Go to step 2b.
   - **GLOBAL (every repo)** — your default vault for all repos via `LUNA_VAULT_PATH`, persisted in `~/.claude/settings.json`'s `env` block. Go to step 2c.

2a. **By name.**
   - Ask for the **vault name** (e.g. `salus`). Validate: 1–64 chars, `[A-Za-z0-9._-]`, must start alphanumeric, no `/` or `..`. Reject otherwise.
   - Resolve the name to a path: if `~/Documents/<name>/.obsidian/` exists, that's the convention target — **no registry entry needed**. Otherwise ask for the absolute vault path (or `~/`-prefixed) and write the mapping into `~/.claude/luna-vaults.json`, preserving existing entries:
     `jq '.vaults = ((.vaults // {}) + {($n): $p})' --arg n "<name>" --arg p "<path>"` (create the file as `{ "vaults": { "<name>": "<path>" } }` if absent). The path should contain an `.obsidian/` marker.
   - Merge `"vault": "<name>"` into this repo's `.claude/end-session-wiki.json`, preserving existing keys: `jq '. + {vault: $n}' --arg n "<name>"`. Create as `{ "vault": "<name>" }` if absent.

2b. **By path (this repo only).** Ask for the absolute path (default `~/Documents/luna`); expand a leading `~/`; validate the dir exists and contains `.obsidian/` — if not, report and stop. Merge `"vault_path": "<path>"` into `.claude/end-session-wiki.json`, preserving existing keys: `jq '. + {vault_path: $p}' --arg p "<path>"`. Create as `{ "vault_path": "<path>" }` if absent.

2c. **Global.** Ask for the absolute path (default `~/Documents/luna`); expand + validate as in 2b. Persist the **expanded** path as `env.LUNA_VAULT_PATH` in the user settings file `~/.claude/settings.json` — that is the process-env mechanism the resolver reads (step 3 above). Do **not** write it to the repo-root `.env`: that file is not bridged for this hook, so the hook would never see it (`.env.example` says so, and it's the wrong scope anyway — `.env` is per-repo, this tier is every repo).

   Use the existing helper rather than hand-editing the JSON — it is idempotent, atomic (temp + `mv`), and preserves every other key (`HIMMEL_REPO`, `statusLine`, …); it refuses to overwrite a settings file that isn't valid JSON. Resolve the himmel checkout first, since this command runs from *your* code repo:

   ```bash
   # Resolve the himmel checkout: $HIMMEL_REPO -> canonical install paths -> error.
   # NOTE: deliberately NO `git rev-parse --show-toplevel` fallback, unlike
   # /himmel-update's otherwise-identical resolver. This command is documented as
   # run from ARBITRARY code repos, so accepting the current repo as the himmel
   # checkout merely because it contains scripts/lib/wire-luna-vault.sh would let
   # a hostile clone supply the script we then execute — with ~/.claude/settings.json
   # as its argument. Trusted locations only; fail closed.
   REPO="${HIMMEL_REPO:-}"
   if [ -z "$REPO" ] || [ ! -f "$REPO/scripts/lib/wire-luna-vault.sh" ]; then
     REPO=""
     for c in "$HOME/Documents/github/himmel" "$HOME/Documents/github/Himmel" "$HOME/github/himmel" "$HOME/github/Himmel"; do
       [ -f "$c/scripts/lib/wire-luna-vault.sh" ] && { REPO="$c"; break; }
     done
   fi
   [ -n "$REPO" ] && [ -f "$REPO/scripts/lib/wire-luna-vault.sh" ] || { echo "ERR: cannot locate himmel checkout — set HIMMEL_REPO to your himmel clone" >&2; exit 1; }

   # Persist a DRIVE-QUALIFIED path on Windows. Git Bash expands ~/Documents/luna
   # to the MSYS form /c/Users/…, which the PowerShell SessionEnd hook resolves
   # under \c\Users\… (Join-Path reads a leading / as the current drive root) —
   # capture would land in the wrong place or fail. cygpath -m converts
   # /c/Users/… -> C:/Users/…; it is absent on POSIX, where the path passes through.
   vault="<expanded-path>"
   case "$vault" in
     /*) command -v cygpath >/dev/null 2>&1 && vault="$(cygpath -m "$vault")" ;;
   esac
   bash "$REPO/scripts/lib/wire-luna-vault.sh" "$HOME/.claude/settings.json" "$vault"
   ```

   PowerShell twin (same contract, and already native — PowerShell never produces an MSYS path): `pwsh -File "$REPO/scripts/lib/wire-luna-vault.ps1" -SettingsPath "$HOME/.claude/settings.json" -VaultPath "<expanded-path>"`.

   A `settings.json` `env` block is applied at **session start**, so say plainly that the value takes effect for **new** sessions — the current session keeps whatever vault it started with. (For a one-off in the current shell, `export LUNA_VAULT_PATH=<path>` before launching `claude` — same drive-qualified requirement on Windows, so `export LUNA_VAULT_PATH="$(cygpath -m ~/Documents/luna)"`, not the bare `~/…` form.)

   **Legacy `.env` cleanup — tell the operator, don't go read the file.** An earlier version of this step wrote `LUNA_VAULT_PATH=` into the repo-root `.env`. That line is inert for the capture hook, but it is NOT inert everywhere: `/himmel-update`'s luna-template step still bridges the key from `.env`, and a bridged value only loses to a value already live in the environment. So a **standalone** `himmelctl update` from a plain shell (no Claude session, nothing exporting the new value) would upgrade the OLD vault. Advise removing or updating that stale line. Do not grep for it yourself — the `block-read-secrets` guard hard-blocks any Bash command whose text contains a `.env` path.

3. **Confirm the REST API key is discoverable.** The hook delivers notes via the Obsidian Local REST API when a key is available, and falls back to writing on disk otherwise. Check whether either:
   - `OBSIDIAN_API_KEY` is set in the environment, OR
   - `<vault>/.obsidian/plugins/obsidian-local-rest-api/data.json` exists.

   If neither is found, warn that REST delivery won't work until they install/enable the Local REST API plugin and set `OBSIDIAN_API_KEY` — but note the **on-disk fallback still captures notes without it** (Obsidian picks up file changes automatically).

4. **Report.** State exactly what you wrote (which file, which key), which precedence tier now wins for this repo, and the absolute vault path sessions will land in. For BY-NAME, show both the repo `vault` key and how the name resolved (registry entry or `~/Documents/<name>` convention). For GLOBAL, name `~/.claude/settings.json` → `env.LUNA_VAULT_PATH` and repeat the **new sessions only** caveat.

Keep it tight. Ask the targeting question, validate, write, confirm — nothing more.
