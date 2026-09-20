# {{PREDECESSOR_LETTER}} → {{LETTER}} handoff state

> Written by {{PREDECESSOR_LETTER}} at handover. **This file wins over the
> {{PREDECESSOR_LETTER}} Results tail** wherever the two differ — the successor
> reads this, and only falls back to the Results tail bottom-up if a section
> here is empty.

**Head:** `<sha>` on `<branch>` at `{{REPO}}`, remote `<origin url>`.
**Bank at write:** 5-hour `<n>` %, 7-day `<n>` %.
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
retype them. Add here what Live state does not carry: each leg's model,
ticket, worktree + branch, brief path, what it last reported and what it
owes next. A leg not listed above is not alive — the successor confirms with
ListAgents regardless.>

## Rulings made this shift

<Numbered, one line each. These are binding on the successor.>

## Held queue (launch order)

<Numbered. Each entry: ticket, one-line scope, the model tier it should get,
and the files it owns — so the successor can collision-check the fan-out
without re-deriving it.>

## Wrapped this shift

<Legs whose windows are closed and locks free, with the PRs they landed.>

## Open operator items

<Things only the operator can do: a merge you cannot make, a credential, a
dashboard flip, a window to close.>
