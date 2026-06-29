---
description: Backfill old Claude session transcripts into the luna vault as structured session notes. TOKEN-INTENSIVE — warns before running and recommends --dry-run first.
argument-hint: [--all | --project <path>] [--reheal | --recrystallize [--limit N]] [--dry-run] [--include-orphaned] [--only <glob>] [--exclude <glob>] [--projects-dir <dir>] [--state-file <path>] [--vault-registry <path>] [--luna-vault-path <dir>]
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

### Full-scope, multi-vault routing (`--all`)

`--all` resolves the vault **per session**, not once for the whole run: each
session is routed to the vault its own repo configures (`.claude/end-session-wiki.json`
`vault_path` / `vault` name, then `LUNA_VAULT_PATH`, then the registry default).
So a single `--all` pass across repos that target **different** vaults files each
repo's sessions into its **own** vault — e.g. a work repo → a work vault and a
personal repo → a personal vault, in one command. Single-vault setups behave
exactly as before (everything lands in the one default). This routing is locked
by a multi-vault test (two repos → two vaults, no cross-contamination).

> **No configured vault → skip (HIMMEL-590).** If no vault is configured for a
> session — no `vault_path`/`vault`, no `LUNA_VAULT_PATH`, no registry entry, and
> no real `~/Documents/luna` (an `.obsidian/` marker) — that session is **skipped**
> with a `vault unresolved` notice. Backfill never materializes a phantom vault.

## All flags

```
--all                    Process every project under ~/.claude/projects
--project <path>         Process the project for the given repo path (repeatable)
--dry-run                Print counts only; write nothing (no note, no ledger update)
--include-orphaned       Also import sessions whose cwd no longer exists on disk
--only <glob>            Only process projects matching glob (repo path)
--exclude <glob>         Exclude projects matching glob (repo path)
--reheal                 Recover existing HUSK notes in the vault (see below)
--recrystallize          Crystallize ANY uncrystallized note with a content-bearing
                         transcript (not just husks) — see below
--limit <N>              Cap real crystallizations per --recrystallize run (0 = unbounded)
--projects-dir <dir>     Override transcripts root (default: ~/.claude/projects) — testing
--state-file <path>      Override ledger path (default: ~/.claude/luna-backfill-state.json)
--vault-registry <path>  Override vault registry (default: ~/.claude/luna-vaults.json)
--luna-vault-path <dir>  Override default vault path (sets LUNA_VAULT_PATH)
```

## Recommended workflow

1. **Dry-run first** — see how many sessions would be imported, split by
   category (new / already-in-ledger / opt-out-skip / orphaned-skip / under-min /
   husk-skip):
   ```bash
   bash scripts/luna/backfill-sessions.sh --dry-run
   ```
2. **Scope check** — if `--all` shows a large `new=` count, consider narrowing
   with `--project <path>` or `--exclude <glob>` to batch the import.
3. **Real run** — only after reviewing the dry-run output:
   ```bash
   bash scripts/luna/backfill-sessions.sh
   ```
4. **Crystallize (quality pass)** — backfill writes **mechanical** notes
   (`crystallized: false`): a slugged Summary from the transcript, no LLM
   synthesis. Backfill deliberately does **not** auto-crystallize each note
   (a bulk `--all` import would fan out an unbounded number of billed `claude`
   runs); instead it prints a nudge and you run the explicit, concurrency-capped,
   idempotent pass over what just landed. A backfilled prose-session note is
   **content-bearing** (not a husk), so **`--recrystallize`** is the mode that
   crystallizes it — `--reheal` is husk-only and would skip it. **Dry-run first**
   to see the count (one real `claude` run per note); `--limit` bounds a batch:
   ```bash
   bash scripts/luna/backfill-sessions.sh --recrystallize --dry-run   # count
   bash scripts/luna/backfill-sessions.sh --recrystallize --limit 25  # apply a batch
   # (add the same --all / --luna-vault-path / --vault-registry scope you used)
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

## Reheal mode (`--reheal`)

`--reheal` is a recovery sweep, not an import. Instead of reading transcripts
into new notes, it scans the **resolved vault's** `sessions/**/*.md` for **husk
notes** and overwrites them in place. A note is a husk when ALL hold:

- frontmatter `crystallized` is **not** `true`, **AND**
- its Raw Conversation contains the literal `_Transcript unavailable._`, **AND**
- its Files Touched section is `_None._`.

For each husk it reads `session_id`, locates
`~/.claude/projects/*/<session_id>.jsonl`, and:

- if that transcript now has salvageable content → overwrites the note via the
  crystallizer; when `claude` is unavailable, a **mechanical re-render** instead
  (real Summary/Commands, still `crystallized: false`) — but only when the
  transcript has a final assistant prose turn. A tool/thinking-only session
  (no prose turn) can only be lifted by the LLM crystallizer, so without
  `claude` it is left as-is for a later run;
- if the transcript is genuinely contentless or missing → leaves the husk
  untouched (cannot recover).

Idempotent: a healed (`crystallized: true`) note — and any note a mechanical
pass can't lift this run — is left byte-unchanged on re-run (no rewrite loop).
Inert husks persist — there is **no auto-delete** (the operator may delete them
by hand). Honours `--dry-run` (reports `healed=N inert=M non-husk-skip=K`, writes
nothing) and the vault-targeting flags. The reheal sweep needs a resolvable
vault: pass `--luna-vault-path <dir>` or rely on `LUNA_VAULT_PATH` / the
registry default.

```bash
# Preview: how many husks are recoverable vs inert?
bash scripts/luna/backfill-sessions.sh --reheal --dry-run --luna-vault-path ~/Documents/luna
# Apply:
bash scripts/luna/backfill-sessions.sh --reheal --luna-vault-path ~/Documents/luna
```

Background: [`docs/luna/end-session-wiki.md` → Crystallization](../../docs/luna/end-session-wiki.md#crystallization-llm-upgrade).

## Recrystallize mode (`--recrystallize`)

`--reheal` only recovers **husks** (`crystallized != true` **AND**
`_Transcript unavailable._` **AND** Files Touched `_None._`). But the common
uncrystallized note is **content-bearing, not a husk** — e.g. a backfilled
prose-session note, or a live note left `crystallized: false` by an earlier
crystallizer bug. `--reheal` *skips* those (`non-husk-skip`).

`--recrystallize` closes that gap: it crystallizes **any** note with
`crystallized != true` that has a **recoverable (content-bearing) transcript**,
husk or not. It is **LLM-only** — with no `claude` it skips (a mechanical
re-render can't crystallize). Idempotent (already-`true` notes are skipped), and
it honours the same `--dry-run` + vault-targeting flags.

Because it is **one real `claude` run per note**, always **dry-run first** to see
the count, then bound a batch with `--limit <N>` (remaining notes recover on a
later run):

```bash
# Preview: how many uncrystallized content-notes would crystallize?
bash scripts/luna/backfill-sessions.sh --recrystallize --dry-run --luna-vault-path ~/Documents/luna
# Apply a bounded batch (e.g. 25 at a time):
bash scripts/luna/backfill-sessions.sh --recrystallize --limit 25 --luna-vault-path ~/Documents/luna
```

> **Sequencing:** run `--recrystallize` to fully crystallize the session corpus
> **before** a memory-compound pass (HIMMEL-564), so compounding works over real
> distilled notes rather than mechanical ones.

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
