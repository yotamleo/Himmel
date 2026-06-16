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
