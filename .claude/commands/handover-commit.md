---
description: Auto-commit *.md changes in the handover root (Mode B / external HANDOVER_DIR only). HIMMEL-59 MVP.
argument-hint: <message> [--push] [--dry-run]
---

Auto-stages and commits *.md changes in the resolved handover root. **Mode B only** — refuses on Mode A (inline `<repo>/handovers/`) to avoid clobbering the active himmel feature branch with handover noise.

Use this after the handover skill writes status updates, next-session notes, or master-plan edits to the external handover root. Saves the manual `cd $HANDOVER_DIR && git add ... && git commit -m ...` cycle.

Mode + root are reportable via `/handover-link` first if you're unsure which mode you're in.

Run:

```bash
bash scripts/handover/auto-commit.sh $ARGUMENTS
```

`$ARGUMENTS` is forwarded UNQUOTED so trailing flags (`--push`, `--dry-run`) are parsed as flags, not appended to the commit message. The script accepts the message as a positional arg.

Common invocations:
- `/handover-commit epic #5 status update` — commit only, no push.
- `/handover-commit wrap session --push` — commit + push to origin.
- `/handover-commit what would happen --dry-run` — show the plan, do nothing.

If your message would otherwise collide with a flag name, use the explicit form: `/handover-commit --message "--push is in the message" --push`.

Exit codes (surfaced by the underlying script):
- `0` committed (or no changes — nothing to do)
- `1` usage / input error
- `2` required tool missing or environment unusable
- `3` Mode A (inline) refused — move handover state to an external repo + set `HANDOVER_DIR` first
- `4` commit failed (git error)
- `5` push failed (commit landed locally, push didn't)

Branching + PR flow are deliberately deferred to a follow-up wedge — they need per-operator workflow preference that's not yet captured by the resolver.
