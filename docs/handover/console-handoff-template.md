# {{PREDECESSOR_LETTER}} → {{LETTER}} handoff state

> Written by {{PREDECESSOR_LETTER}} at handover. **This file wins over the
> {{PREDECESSOR_LETTER}} Results tail** wherever the two differ — the successor
> reads this, and only falls back to the Results tail bottom-up if a section
> here is empty.

**Head:** {{HEAD_LINE}}
**Bank at write:** {{BANK_LINE}}
**Operator:** `<at the station / away / asleep>`.

## How {{LETTER}} starts

Run ACTION ZERO from `{{SUCCESSOR_DOC}}` unchanged. Expect at the root sweep:
`<the locks the successor should find>`. Kit is in-tree at `{{KIT}}`.
The live legs and their tokens are listed below. A relay MAY keep a
leg's token, so rotating it to `{{LETTER}}-<leg>-<hex>` is optional, not a
precondition of succession. Ask the {{PREDECESSOR_LETTER}} console session
(`{{PREDECESSOR}}` minus the `.md`) to re-brief each inherited leg from its own
socket, naming you and quoting the leg's current token (plus your fresh one only
if you chose to issue one), and wait for each leg's quote-back — **the tokens in
the list below are the predecessor's, and a leg is yours only once it has quoted
back**; until then do not treat them as yours. Only then send **`{{LETTER}} LIVE`** to that
session so it releases its lock and wraps — or, for a leg that stays silent,
send it with that leg named as one that did not quote back, and why (ACTION
ZERO step 9), rather than waiting on it indefinitely. `LIVE` first strands
every leg that has not been re-briefed (HIMMEL-3254).

## In flight

{{LIVE_STATE}}

<Copied verbatim from the predecessor's `## Live state` (HIMMEL-2973 S1) —
each leg's nonce, lock release token and pid are already there; do not
retype them. A leg not listed above is not alive — the successor confirms with
ListAgents regardless.>

**Legs** (fleet manifest, last Results marker of each; `console.sh next`
filled this, HIMMEL-4902):

{{LEG_LIST}}

**Open PRs:**

{{OPEN_PRS}}

**Held queue:** {{QUEUE_LINE}}
**Last GO:** {{LAST_GO}}

## This shift (the console's last Results bullets)

{{SHIFT_SUMMARY}}

## Rulings and judgement notes — the only part the console writes

<Numbered, one line each: the operator rulings binding on the successor, and
anything the pre-filled sections above cannot know — each leg's model, brief
path and what it owes next; the held queue's model tiers and owned files so
the successor can collision-check the fan-out. One Edit replaces this block.>

## Wrapped this shift

<Legs whose windows are closed and locks free, with the PRs they landed.>

## Open operator items

<Things only the operator can do: a merge you cannot make, a credential, a
dashboard flip, a window to close.>
