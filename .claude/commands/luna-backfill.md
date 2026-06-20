---
description: Backfill old Claude session transcripts into the luna vault as structured session notes. TOKEN-INTENSIVE — warns before running and recommends --dry-run first.
argument-hint: [--all | --project <path>] [--dry-run] [--include-orphaned] [--only <glob>] [--exclude <glob>] [--projects-dir <dir>] [--state-file <path>] [--vault-registry <path>] [--luna-vault-path <dir>]
---

> **TOKEN-USAGE WARNING:** Backfill seeds many session notes into the vault at
> once. If you follow up immediately with `/triage-clips`, `/synthesize-clips`,
> or any pipeline stage over those notes, the downstream pass can cost
> significant tokens — proportional to how many sessions are backfilled.
> **Run `--dry-run` first** to see the count before committing to a real write.
> A large backfill (hundreds of sessions) is best done in batches.

Render historical Claude session transcripts into the luna vault as structured
session notes (same schema as the live `end-session-wiki` hook, with
`source: claude-backfill`). Notes are written CREATE-only — existing notes
and ledger entries are never overwritten (idempotent re-runs are safe).

## Scope flags (default = current project)

| Flag | Scope |
|------|-------|
| *(none)* | Current project only — the `~/.claude/projects/<slug>` matching the current repo |
| `--all` | Every project under `~/.claude/projects` |
| `--project <path>` | A specific repo path (repeatable for multiple) |

## All flags

```
--all                    Process every project under ~/.claude/projects
--project <path>         Process the project for the given repo path (repeatable)
--dry-run                Print counts only; write nothing (no note, no ledger update)
--include-orphaned       Also import sessions whose cwd no longer exists on disk
--only <glob>            Only process projects matching glob (repo path)
--exclude <glob>         Exclude projects matching glob (repo path)
--projects-dir <dir>     Override transcripts root (default: ~/.claude/projects) — testing
--state-file <path>      Override ledger path (default: ~/.claude/luna-backfill-state.json)
--vault-registry <path>  Override vault registry (default: ~/.claude/luna-vaults.json)
--luna-vault-path <dir>  Override default vault path (sets LUNA_VAULT_PATH)
```

## Recommended workflow

1. **Dry-run first** — see how many sessions would be imported, split by
   category (new / already-in-ledger / opt-out-skip / orphaned-skip / under-min):
   ```bash
   bash scripts/luna/backfill-sessions.sh --dry-run
   ```
2. **Scope check** — if `--all` shows a large `new=` count, consider narrowing
   with `--project <path>` or `--exclude <glob>` to batch the import.
3. **Real run** — only after reviewing the dry-run output:
   ```bash
   bash scripts/luna/backfill-sessions.sh
   ```

## Opt-out + skip rules

- A project with `.claude/end-session-wiki.json` `"enabled": false` is skipped.
- Sessions shorter than `min_duration_seconds` (default 60 s) in the project
  config are skipped.
- Sessions whose `cwd` no longer exists on disk are skipped unless
  `--include-orphaned` is passed. Note: orphaned sessions bypass the
  per-repo `enabled:false` opt-out (the repo config is gone with the
  deleted directory), so `--include-orphaned` is an explicit operator
  choice to import them regardless.
- The ledger (`~/.claude/luna-backfill-state.json`) short-circuits sessions
  already imported — re-running is safe at any time.

## First-run note (live-capture overlap)

On the first backfill into a vault, the tool prints a warning that
live-captured sessions (from the `end-session-wiki` hook) may produce
duplicate notes for sessions that are already in the vault. Review
`sessions/<YEAR>/<MONTH>/` after backfilling.

## Run

```bash
bash scripts/luna/backfill-sessions.sh $ARGUMENTS
```

Common invocations:
- `/luna-backfill --dry-run`
- `/luna-backfill`
- `/luna-backfill --all --dry-run`
- `/luna-backfill --project ~/Documents/github/my-repo`
- `/luna-backfill --project ~/Documents/github/repo-a --project ~/Documents/github/repo-b`
- `/luna-backfill --all --exclude "*/personal/*"`
