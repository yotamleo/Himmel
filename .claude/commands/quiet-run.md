---
description: Run a noisy command quietly — one OK/ERR line + log path
argument-hint: <label> -- <command...>
---

Wrap any verbose command so it doesn't spam the session. Prints one line with exit status, duration, and log path. Caller (you) can grep the log if more detail is needed.

Run:

```bash
bash scripts/quiet-run.sh $ARGUMENTS
```

Examples:
- `/quiet-run npm-install -- npm install` (in scripts/jira/)
- `/quiet-run pytest -- pytest -xvs tests/`
- `/quiet-run build -- npm run build`

Convention: `<label>` is a short slug for log-file naming (`/tmp/quiet-run-<label>-<ts>-<pid>.log`). Use the same label across runs of the "same" command so logs are easy to find.

Lifetime (HIMMEL-2221): a quiet-run started in the background is a **live child of your session** — count it (and any `tail -f` / `Monitor` you pointed at its log) when you decide "zero live children" before closing or wrapping, not just Agent-tool subagents. Killing quiet-run with TERM/INT/HUP reaps the whole command tree it wraps (exit 128+signal); SIGKILL cannot be trapped and still orphans it. A `tail -f` on the log is yours to stop — quiet-run starts none.
