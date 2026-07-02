---
template_version: 2
---
# Next Session — Task #N <Name>

**Last updated:** YYYY-MM-DD

## Progress

- Done: ...
- Remaining: ...

## Resume Point

[Exact next step — one sentence]

## Cold-Start Prompt

Paste into new Claude Code session to resume:

---
Continue task #N <name> (epic #M <epic-name>) in repo <repo-name>.

Load context:
- <state-root>/epics/#M-<epic-slug>/context.md
- <state-root>/epics/#M-<epic-slug>/tasks/#N-<slug>/brief.md

Load latest session: <state-root>/epics/#M-<epic-slug>/tasks/#N-<slug>/next-session-<latest>.md

[Any extra critical context here]
---

## Overnight Mode Trigger

If the user prompt includes the phrase **"overnight mode"** alongside this file path, run the full autonomous pipeline end-to-end without pausing for confirmation between phases.

Standing instructions for the autonomous run (HIMMEL-281, Fable-5 preamble):
<!-- source of truth: docs/handover/overnight-mode.md § Fable-5 launch preamble — edit there first, then sync the three template copies -->

> When you have enough information to act, act. Do not re-derive facts already established in the conversation, re-litigate a decision the user has already made, or narrate options you will not pursue in user-facing messages. If you are weighing a choice, give a recommendation, not an exhaustive survey. This does not apply to thinking blocks.

> You have ample context remaining. Do not stop, summarize, or suggest a new session on account of context limits. Continue the work.

See [`docs/handover/overnight-mode.md`](../../../../docs/handover/overnight-mode.md) for the 11-phase pipeline, budget, block criteria, and lessons learned from HIMMEL-97.
