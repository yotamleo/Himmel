---
template_version: 2
resume_cwd: <repo-root>
---
# Next Session — Task #N <Name>

**Last updated:** YYYY-MM-DD

## Console Rulings

A claudex leg (`scripts/claude-codex`) has no `ListAgents`/`SendMessage` reach
— its rulings arrive via the inbox hook instead
(`scripts/hooks/claudex-inbox-hook.sh`, fed by `inbox-send.sh`), delivered as
`additionalContext` on the next tool result, no operator paste. A native leg
gets rulings the normal way, via a direct `SendMessage`. Either way, this
doc's own **## Console Rulings** section (appended below as rulings land) is
the record — check it, don't wait on it.

report at MILESTONES only (LIVE, FINDING, READY, BLOCKED, HALTED, WRAPPED); no progress chatter; acks to a rotation are one line.

## Leg Handover Threshold

After every substantial turn, read both thresholds:

```bash
bash scripts/context-fill.sh --warn-at 45
bash scripts/context-fill.sh --warn-at 90000
```

Hand over before the next turn at **45% context fill OR 90,000 input tokens this turn, whichever comes first**. The token readout is the latest assistant
turn's `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`
from this session's own transcript; it is not cumulative spend and does not
include output tokens.

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

## Operator-Gated Wrap

If your only remaining dependency is an operator action, **wrap at once** — do
not idle-wait. Append a RESUME BRIEF to this file (worktree, branch, base SHA,
dirty paths, the verbatim operator block, the ordered remaining steps), release
the queue lock, message the console `OPERATOR-GATED, wrapped, safe to close`,
and end the turn. **Never idle-wait for the operator** — an idle leg holds the
queue lock, burns its prompt cache and emits no signal, so it is
indistinguishable from a crashed one. The console resumes it from that brief
(`bash scripts/handover/leg-resume-brief.sh <this file>` regenerates the
skeleton from git) instead of waking a cold session to ask.

"End the turn" means the session actually **ends** — the harness exits. A
message announcing that you are closing is not closing: a leg that says
"safe to close" and stays resident holds its RAM, keeps its queue lock, and
still reads as live in `ListAgents`. If you cannot end your own session,
say exactly that in your final message so the console can list you for the
operator instead of assuming you are gone.

## Overnight Mode Trigger

If the user prompt includes the phrase **"overnight mode"** alongside this file path, run the full autonomous pipeline end-to-end without pausing for confirmation between phases.

Standing instructions for the autonomous run: apply `docs/handover/overnight-mode.md` § Launch preamble — the single copy of the launch-preamble text (HIMMEL-1719). Do not inline it here.

See [`docs/handover/overnight-mode.md`](../../../../docs/handover/overnight-mode.md) for the 11-phase pipeline, budget, block criteria, and lessons learned from HIMMEL-97.
