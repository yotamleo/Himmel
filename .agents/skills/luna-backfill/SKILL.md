---
name: luna-backfill
description: Backfill old Claude session transcripts into the luna vault as structured session notes. TOKEN-INTENSIVE — recommend --dry-run first. Use when the user asks to backfill sessions into luna or runs /luna-backfill.
---

# luna-backfill

When the user asks to backfill session transcripts into luna, run:

    bash scripts/luna/backfill-sessions.sh [--all | --project <path>] [--reheal | --recrystallize [--limit N]] [--dry-run] [--include-orphaned] [--only <glob>] [--exclude <glob>] [--projects-dir <dir>] [--state-file <path>] [--vault-registry <path>] [--luna-vault-path <dir>]

**TOKEN-INTENSIVE** — seeds many session notes at once; a follow-up pipeline pass
over them can cost significant tokens. **Run `--dry-run` first** to see the count;
do large backfills in batches. Notes are written CREATE-only (idempotent). Default
scope = current project; `--all` routes each session to its own repo's vault. See
`.claude/commands/luna-backfill.md`.
