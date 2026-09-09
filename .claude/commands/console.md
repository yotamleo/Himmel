---
description: Start a console session (new) or hand it over (next) — writes the doc, takes the queue lock, prints the launch line.
argument-hint: new|next [--bucket <slug>] [--name <slug>] [--arm] [--dry-run] [--doc <path>] [--model <m>]
---

A **console** is a long-running session that dispatches implementation legs,
rules on their questions, relays merges and arms its successor. It does no
implementation itself. Background + the operating contract:
[`docs/handover/running-a-console.md`](../../docs/handover/running-a-console.md).

Run:

```bash
bash scripts/handover/console/console.sh $ARGUMENTS
```

- `/console new` — write `<handover-root>/<user>/<bucket>/<PREFIX>-nextleg-<date>A-console.md`
  from `docs/handover/console-template.md`, acquire the queue lock on it, and
  print the launch line. A second `new` the same day bumps the letter; it never
  overwrites.
- `/console next` — from a running console, write the successor stub (letter
  bumped, pointed at this console and its HANDOFF) plus this console's
  `-HANDOFF.md` skeleton. Run it at 45 % context fill or after 90 k input
  tokens in one turn.
- `--arm` — also arm the session headed via `scripts/handover/headed-arm.sh`,
  on a signal file plus a deadline; prints the arm log path.
- `--dry-run` — print what it would write, prefixed `would-`, and touch nothing.

Record the printed `release-token:` line in the console's first Results bullet:
releasing the lock at wrap requires it.

Linux/macOS only — `--arm` launches through konsole. The Windows station arms
through `scripts/handover/arm-resume.sh`'s schtasks backend instead.
