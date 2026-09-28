#!/usr/bin/env bash
# scripts/handover/console-kit/append-results.sh - HIMMEL-3794: append a
# leg's marker bullet at a handover doc's true EOF, so it can never land
# mid-doc. Twice in one shift a leg's WRAPPED bullet, written with the Edit
# tool anchored on an earlier bullet, landed ABOVE later bullets instead of
# at the true end of the doc; close-wrapped-leg.sh and tick.sh both read the
# doc's LAST `- ` line (scripts/lib/leg-tail-status.sh) as the leg's current
# status, so the misordered WRAPPED bullet was invisible to them and the
# wrap was refused. This script always appends at the literal end of the
# file, so a leg calling it can never repeat that mistake.
#
# Usage: append-results.sh <doc> <text>
#
# Writes `- HH:MM <text>` as a new final line of <doc> (the timestamp is
# always the current wall-clock HH:MM, never taken from <text>). If the file
# does not already end in a newline, one is added first, so the new bullet
# is never glued onto a prior line. Refuses - doc left byte-for-byte
# unchanged - unless the file exists, is readable and writable, and
# contains a literal `## Results` heading line somewhere in it (a doc with
# no Results section has nowhere defined to append a Results bullet).
#
# Exit codes:
#   0  appended
#   2  usage (wrong arg count)
#   3  doc missing / unreadable / unwritable
#   4  doc has no `## Results` heading - nothing written
#   5  write failed (e.g. disk full) after the heading/newline checks passed
#
# Platform guard: POSIX bash 3.2+, no GNU-only flags.
set -u

if [ "$#" -ne 2 ]; then
    echo "usage: append-results.sh <doc> <text>" >&2
    exit 2
fi
DOC="$1"
TEXT="$2"

if [ ! -f "$DOC" ] || [ ! -r "$DOC" ] || [ ! -w "$DOC" ]; then
    echo "append-results: cannot read/write doc '$DOC'" >&2
    exit 3
fi

if ! grep -q '^## Results' "$DOC"; then
    echo "append-results: '$DOC' has no '## Results' heading - refusing" >&2
    exit 4
fi

stamp="$(date +%H:%M)"
bullet="- ${stamp} ${TEXT}"

# Command substitution strips trailing newlines, so a non-empty result here
# means the file's last byte is NOT a newline.
if [ -s "$DOC" ] && [ -n "$(tail -c 1 "$DOC")" ]; then
    printf '\n' >> "$DOC"
fi

if ! printf '%s\n' "$bullet" >> "$DOC"; then
    echo "append-results: write failed for $DOC" >&2
    exit 5
fi
echo "append-results: appended to $DOC"
