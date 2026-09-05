---
name: retitle
description: Infer a himmel-canonical session name from the current branch and print a /rename line. Use for /retitle.
---

# retitle

When the user asks to retitle the session, run:

    bash scripts/retitle.sh [TICKET-ID ...]

Computes `<TICKET-ID[/TICKET-ID...]> <meaningful name>` from the current git
branch and prints a ready-to-paste line for the harness's **built-in** `/rename`
(the agent cannot set the session name itself). Pass extra ticket IDs for a
multi-ticket session. Print the line; the user applies it with the built-in
rename. See `.claude/commands/retitle.md`.
