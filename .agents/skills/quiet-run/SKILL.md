---
name: quiet-run
description: Run a noisy command quietly — one OK/ERR line plus a log path. Use for /quiet-run.
---

# quiet-run

When the user asks to run a verbose command quietly, run:

    bash scripts/quiet-run.sh <label> -- <command...>

Wraps any verbose command so it doesn't spam the session — prints one line with
exit status, duration, and log path (`/tmp/quiet-run-<label>-<ts>-<pid>.log`).
`<label>` is a short slug for log naming; everything after `--` is the command.
Grep the log if more detail is needed. See `.claude/commands/quiet-run.md`.

A background quiet-run is a live child of your session: count it (and any `tail -f`
or `Monitor` on its log) as a live child before closing or wrapping, not just
Agent-tool subagents. Killing it with TERM/INT/HUP reaps the whole command tree
when its stdin is not a terminal (every agent/CI run); with a tty on stdin it keeps
the foreground shape so the command can read the tty. SIGKILL cannot be trapped.
