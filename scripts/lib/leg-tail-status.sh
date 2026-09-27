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
# HIMMEL-3747 Ask 4: WRAPPED is the one exception, and only when the FINAL
# bullet has no leading marker of its own (so it would otherwise be invisible,
# per the ponytail above) -- it is the wrap signal a leg never gets a second
# chance to send (the window closes right after), so a bullet like
# `- 10:15 Released lock \`tok\`, appended the WRAPPED bullet, ending turn`
# still reads WRAPPED instead of falling through to the last bullet that DID
# lead with a marker. A bullet whose leading token IS a recognized marker
# keeps HIMMEL-3393's rule untouched: `- 23:47 LIVE -- was BLOCKED, then
# WRAPPED nothing` still reads LIVE, never WRAPPED, because LIVE already
# leads it. And an earlier bullet mentioning the word (a FINDING asking
# whether to wait for WRAPPED, say) is never retroactively promoted -- only
# the truly last bullet in the doc is checked this way.
#
# Source this file; it defines one function, runs nothing. Bash 3.2-compatible.
leg_tail_status() {  # leg_tail_status <leg doc> -- prints the marker, or nothing
    local marker_re='^- ([0-9]{1,2}:[0-9]{2}[[:space:]]+)?(\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE)([^A-Za-z0-9_].*)?$'
    local final
    final=$(sed -nE '/^- /p' "$1" 2>/dev/null | tail -n 1)
    if [ -z "$final" ]; then
        return
    fi
    if printf '%s\n' "$final" | grep -qE "$marker_re"; then  # pipefail-ok: $final is one already-extracted line, far under the pipe buffer size
        printf '%s' "$final" | sed -nE "s/$marker_re/\\3/p" | tr -d '\n'
        return
    fi
    if printf '%s' "$final" | grep -qE '(^|[^A-Za-z0-9_])WRAPPED([^A-Za-z0-9_]|$)'; then  # pipefail-ok: same $final, same reasoning
        printf 'WRAPPED'
        return
    fi
    sed -nE "s/$marker_re/\\3/p" "$1" 2>/dev/null | tail -n 1 | tr -d '\n'
}
