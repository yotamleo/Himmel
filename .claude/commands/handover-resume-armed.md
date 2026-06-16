---
description: Fast-resume from the last armed session — surface its transcript + stop-point (the answered AskUserQuestion = the agreed continuation) with no manual JSONL archaeology. HIMMEL-208.
argument-hint: (no args)
---

Run the fast-resume resolver and act on its summary:

```bash
bash scripts/handover/resume-armed.sh
```

Shells to the bun `armed-session-track.ts resolve` (breadcrumb A-path, else newest-`load`-transcript degrade) and prints where the last armed session stopped — including the last `AskUserQuestion` and the user's answers, which are the agreed continuation. Read-only: it does NOT relaunch. Use it at the top of a scheduler-relaunched session to recover context in one step.
