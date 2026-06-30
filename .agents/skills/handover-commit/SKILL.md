---
name: handover-commit
description: Auto-commit *.md changes in the handover root (Mode B / external HANDOVER_DIR only). Use when the user asks to commit handover state or run /handover-commit.
---

# handover-commit

When the user asks to commit handover state, run:

    bash scripts/handover/auto-commit.sh <message> [--push] [--dry-run]

`<message>` is the commit message (positional); trailing `--push` / `--dry-run`
are flags, not part of the message. Mode B only — refuses (rc=3) on Mode A
(inline `<repo>/handovers/`). Check the mode first with `handover-link` if unsure.
See `.claude/commands/handover-commit.md` for exit codes + the explicit
`--message` form.
