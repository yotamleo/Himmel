---
name: context-hop
description: Jump mid-session to a fresh claude session when context nears the soft budget. Use for /context-hop.
---

# context-hop

When the user asks to context-hop, run:

    bash scripts/handover/hop.sh [--message "what to pick up"] [--delay <minutes>] [--print] [--dry-run] [--force]

Writes a point-in-time snapshot to the handover root, then schedules a relaunch
via `arm-resume.sh` (default, ~2 min delay) or prints the command (`--print`).
Use when nearing ~75-80% of the context window to `/exit` and pick up cleanly.
This shells the SANCTIONED hop path (inherits the arm-resume dedup + cd-into-repo
contract). See `.claude/commands/context-hop.md` for snapshot shape + exit codes.
