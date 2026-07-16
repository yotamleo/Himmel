---
allowed-tools: Bash, Read, AskUserQuestion
description: Resume a tracked handover item to continue the chain — surface its cold-start (brief/context, latest session, open bugs, CR findings). No arg → pick from active items. Read-only (no worktree gate). Script-driven — calls scripts/handover/resume.sh directly, does NOT load the 47KB handover skill (HIMMEL-1038). The token-lean equivalent of "load <ID>". To recover an interrupted/armed session, use /handover-resume-armed instead. HIMMEL-1034.
argument-hint: "[#N | HIMMEL-N | <ID>]  (omit → pick from active items; append 'overnight' for overnight mode)"
---

This is the **chain-resume** path — load a tracked handover item to *continue
work*. It is deliberately distinct from `/handover-resume-armed`, which
*recovers* an interrupted/armed session's stop-point (transcript + last
`AskUserQuestion`). resume ≠ recovery.

**Script-driven (HIMMEL-1038):** resume is read-only and fully mechanical, so
this command calls `scripts/handover/resume.sh` directly and does **not** invoke
the handover skill — avoiding the ~47KB `SKILL.md` load (~7% of context) that the
skill path incurred. The script resolves the target repo + bucket from
`~/.claude/handover/registry.json` (HANDOVER_DIR comes from the environment).

## What to do

1. Parse `$ARGUMENTS`:
   - If the word **`overnight`** appears anywhere, set an overnight flag and strip
     that token first.
   - Of the remaining tokens: **zero or one** is accepted. The single token (if
     present) is the item ID: `#N`, `HIMMEL-N`, or a bare number. Omit → no ID.
   - **Reject anything else.** If, after stripping `overnight`, more than one token
     remains — or the lone token is not a valid ID form — do NOT guess: stop and
     print a clear unsupported-argument error naming the accepted forms
     (`/handover-resume [ID] [overnight]`). The phase-2 chain-action params
     (`merge-private`, `merge-public`, `propagate-only`, `minerva-full`,
     `plan-only`, `arm-successor`) are **not implemented yet** (HIMMEL-1034), so a
     token like `merge` is unsupported today rather than silently ignored.
     (The script also validates the ID form and exits rc 2 on a bad one, but do
     the reject up-front so a bad token never reaches the script.)

2. Run the resume script (read-only) from the repo root:
   - **ID given:** `bash scripts/handover/resume.sh <ID>` — prints the item's
     latest session's Cold-Start Prompt (fallback: `brief.md`/`context.md`), any
     open bugs, the latest CR findings, and a stale nudge. Present that output.
   - **No ID:** `bash scripts/handover/resume.sh --list` prints active items, one
     per line as `ID<TAB>slug<TAB>status<TAB>type`. Offer the top items via
     **AskUserQuestion** (plus an "Other (enter ID)" option), then run
     `bash scripts/handover/resume.sh <chosen-ID>`. If `--list` prints nothing,
     free-text prompt for an ID.
   - **Non-zero exit:** relay the script's stderr line and stop — `rc 2` =
     usage/hard error (bad ID form, unreadable registry), `rc 3` = graceful (no
     repo match in the registry, or no item with that ID).

3. Act on the printed cold-start: load the referenced files and continue the work
   from the item's stop-point.

4. **If the overnight flag was set** (e.g. `/handover-resume HIMMEL-1033 overnight`):
   after loading the item, treat this as the overnight-mode trigger for that item's
   latest `next-session-*.md` and run the autonomous pipeline per
   [`docs/handover/overnight-mode.md`](../../../../docs/handover/overnight-mode.md)
   without pausing between phases.

## Not yet implemented (phase 2 — HIMMEL-1034)

Chain-action params — `merge-private`, `merge-public`, `propagate-only`,
`minerva-full`, `plan-only`, `arm-successor` — will delegate to the existing
initiative-leg (`scripts/lib/initiative-legs.sh`), `arm-resume`, minerva, and
propagate-public systems. This MVP ships plain chain-resume + the `overnight`
passthrough only.
