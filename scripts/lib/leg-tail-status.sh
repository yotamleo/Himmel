#!/usr/bin/env bash
# leg-tail-status.sh — the ONE marker-bullet parser (HIMMEL-3635).
#
# tick.sh's tails= and close-wrapped-leg.sh's WRAPPED gate both read a leg
# doc's newest status bullet; before this file they used two different
# regexes, and close-wrapped-leg.sh's cruder one refused a `WRAPPED:` bullet
# (colon-suffixed) that tick.sh correctly accepted as WRAPPED. One parser,
# sourced by both, so they can never drift apart again.
#
# HIMMEL-3305 / HIMMEL-3393: a leg's tails= status is the marker its newest
# status bullet STARTS with. The vocabulary (docs/handover/leg-preface.md -- change
# the two together) is LIVE / FINDING / RESOLVED / READY / BLOCKED / HALTED / WRAPPED.
# RESOLVED retires a FINDING the console has answered: without it FINDING stayed
# the newest marker for the whole window the leg spent doing the authorised work.
# A status bullet is `- [HH:MM] <MARKER> ...` (a bold `**MARKER**` also reads). The
# status is that leading token, never a word further into the text: HIMMEL-3305
# took the highest-precedence marker anywhere in the bullet, so `- 23:47 LIVE --
# ... not a FINDING ...` read FINDING and the board asked the console for a ruling
# the leg never requested. A marker is a whole word (FINDINGS / UNRESOLVED are not
# markers). A bullet that does not start with one carries no status and is skipped:
# SHIPPED / MERGED are deliberately NOT markers -- a leg between GREEN and READY
# reports LIVE.
# ponytail: a status bullet that leads with something other than the marker
# (`- Sent READY to the console`) is invisible here; the tick reads the last bullet
# that does lead with one.
#
# Source this file; it defines one function, runs nothing. Bash 3.2-compatible.
leg_tail_status() {  # leg_tail_status <leg doc> -- prints the marker, or nothing
    sed -nE 's/^- ([0-9]{1,2}:[0-9]{2}[[:space:]]+)?(\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE)([^A-Za-z0-9_].*)?$/\3/p' "$1" 2>/dev/null \
        | tail -n 1 | tr -d '\n'
}
