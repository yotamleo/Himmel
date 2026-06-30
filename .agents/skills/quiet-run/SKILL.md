---
name: quiet-run
description: Run a noisy command quietly — one OK/ERR line + log path. Use when the user asks to run something quietly or runs /quiet-run.
---

# quiet-run

When the user asks to run a verbose command quietly, run:

    bash scripts/quiet-run.sh <label> -- <command...>

Wraps any verbose command so it doesn't spam the session — prints one line with
exit status, duration, and log path (`/tmp/quiet-run-<label>-<ts>-<pid>.log`).
`<label>` is a short slug for log naming; everything after `--` is the command.
Grep the log if more detail is needed. See `.claude/commands/quiet-run.md`.
