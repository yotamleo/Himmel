---
allowed-tools: Skill, Bash, Read, Glob, Grep, AskUserQuestion
description: Resume a tracked handover item to continue the chain — surface its cold-start (brief/context, latest session, open bugs, CR findings). No arg → pick from active items. Read-only (no worktree gate). The token-lean equivalent of "load <ID>". To recover an interrupted/armed session, use /handover-resume-armed instead. HIMMEL-1034.
argument-hint: "[#N | HIMMEL-N | <ID>]  (omit → pick from active items; append 'overnight' for overnight mode)"
---

This is the **chain-resume** path — load a tracked handover item to *continue
work*. It is deliberately distinct from `/handover-resume-armed`, which
*recovers* an interrupted/armed session's stop-point (transcript + last
`AskUserQuestion`). resume ≠ recovery.

## What to do

1. Parse `$ARGUMENTS`:
   - If the word **`overnight`** appears anywhere in `$ARGUMENTS`, set an
     overnight flag and strip that token first.
   - Of the remaining tokens: **zero or one** is accepted. The single token (if
     present) is the item ID: `#N`, `HIMMEL-N`, or a bare number. Omit → no ID.
   - **Reject anything else.** If, after stripping `overnight`, more than one
     token remains — or the lone token is not a valid ID form (`#N` /
     `<PROJECT>-N` / bare number) — do NOT guess: stop and print a clear
     unsupported-argument error naming the accepted forms
     (`/handover-resume [ID] [overnight]`). Note that the phase-2 chain-action
     params (`merge-private`, `merge-public`, `propagate-only`, `minerva-full`,
     `plan-only`, `arm-successor`) are **not implemented yet**, so a token like
     `merge` is unsupported today rather than silently ignored.

2. Invoke the handover skill's read-only `handover-resume` operation with the
   ID (or no ID). Use the **Skill** tool → `handover` with args
   `handover-resume <ID>` (pass no ID to run the picker).

   The skill op (read-only — no worktree gate) resolves the target repo +
   bucket and then:
   - **no ID** → runs the No-ID picker over active items and prompts for one.
   - **`#N` / `HIMMEL-N` / bare ID** → finds the item and prints its latest
     session's Cold-Start Prompt (or the brief/context as a fallback), plus any
     open bugs and the latest CR findings.

3. Act on the printed cold-start: load the referenced files and continue the
   work from the item's stop-point.

4. **If the overnight flag was set** (e.g. `/handover-resume HIMMEL-1033 overnight`):
   after loading the item, treat this as the overnight-mode trigger for that
   item's latest `next-session-*.md` and run the autonomous pipeline per
   [`docs/handover/overnight-mode.md`](../../../../docs/handover/overnight-mode.md)
   without pausing between phases.

## Not yet implemented (phase 2 — HIMMEL-1034)

Chain-action params — `merge-private`, `merge-public`, `propagate-only`,
`minerva-full`, `plan-only`, `arm-successor` — will delegate to the existing
initiative-leg (`scripts/lib/initiative-legs.sh`), `arm-resume`, minerva, and
propagate-public systems. This MVP ships plain chain-resume + the `overnight`
passthrough only.
