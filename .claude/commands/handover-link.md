---
description: Report or check where Claude is reading/writing handover state (inline ./handovers or external $HANDOVER_DIR)
argument-hint: [status|doctor]
---

Wraps `scripts/handover-link.sh`. Default verb is `status`.

Modes:
- **A — inline**: `HANDOVER_DIR` unset; handovers live in `<repo>/handovers/`. Default for fresh clones.
- **B — external**: `HANDOVER_DIR` points to an existing directory (typically a separate repo like `<state-repo>/handovers`). Set in the shell that launched Claude Code — env is session-sticky.

Verbs:
- `/handover-link` — print resolved root + mode (default `status`).
- `/handover-link doctor` — same as status but exits non-zero on misconfiguration. Useful in CI / pre-push gates.

Run:

```bash
bash scripts/handover-link.sh $ARGUMENTS
```

Migration of `handovers/<owner>/` to `$HANDOVER_DIR` is intentionally NOT in this command — it's a separate manual step (or a follow-up PR adding a `migrate` verb) so the link mechanism can ship and be exercised before any content moves.
