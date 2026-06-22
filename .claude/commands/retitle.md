---
description: Infer a himmel-canonical session name (TICKET-ID + meaningful name) from the current branch and print a ready-to-paste built-in /rename line.
argument-hint: [TICKET-ID ...]
---

Compute the himmel-canonical session name — `<TICKET-ID[/TICKET-ID...]> <meaningful name>` — from the current git branch and print a ready-to-paste line for Claude Code's **built-in** `/rename`.

Why a helper and not an auto-setter: the agent can't set the session name from inside a running session — it's set only by the user-typed built-in `/rename` (mid-session) or the `-n`/`--name` launch flag, and a slash command is a prompt to Claude, not a programmatic command bus, so Claude can't invoke `/rename` itself. So `/retitle` does the inference the native auto-generate doesn't (it anchors on the ticket, not a conversation summary) and hands you the line to paste.

Run:

```bash
bash scripts/retitle.sh $ARGUMENTS
```

Then copy the printed `/rename …` line and run it. Pass extra ticket IDs as arguments for a session that spans tickets (e.g. `/retitle HIMMEL-430` → `HIMMEL-432/HIMMEL-430 …`).

Notes:
- The built-in `/rename` sets the session display name shown in the `/resume` picker and on the prompt bar. To also set your terminal's tab title, relaunch with the name baked in: `claude -n "<name>"` (the `-n` flag sets the terminal title at launch).
- Distinct from the built-in `/rename` on purpose (a `.claude/commands/rename.md` would collide with it); `/retitle` only computes + prints, you apply with the built-in.
