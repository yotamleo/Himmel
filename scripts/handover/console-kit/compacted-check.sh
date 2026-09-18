#!/usr/bin/env bash
# scripts/handover/console-kit/compacted-check.sh - G11 (HIMMEL-2973): prove a
# console's post-compaction COMPACTED bullet matches the snapshot the
# PreCompact hook (scripts/hooks/console-precompact-snapshot.sh) took at the
# moment of compaction.
#
# Usage: compacted-check.sh <console-doc> <snap-dir>
#
# Exit codes:
#   0  `G11 ok`           the doc's last COMPACTED bullet matches the newest snap
#   1  `G11 LOSS <field>` one line per field that differs (or `G11 LOSS bullet`
#                         when the doc has no COMPACTED bullet at all)
#   2  `no snapshot` / `snapshot corrupt`   preservation is UNVERIFIED, which
#                         the gate treats as a loss (plan Task 11 Step 3)
#   64 usage
#
# The bullet format is the one docs/handover/console-template.md ships under
# `## Compact instructions`:
#   - COMPACTED <HH:MM> — legs: <..>, queue: <..>, last GO: <..>[, acked: <..>]
# Compared fields: legs, queue, last-go always; acked only when the bullet
# carries the trailer. Values are compared as exact strings after stripping
# backticks (the template mandates one backtick span per token, and anything
# comparing them strips backticks first).
#
# ponytail: the snap also records `lock` and `go-file` (the queue-lock token
# and the newest .locks/go/ file) but the shipped bullet format carries
# neither, so they are NOT compared here - they exist for forensics and for a
# successor that needs the lock token the compacted console held. Adding
# `lock:` to the bullet would need a console-template.md edit plus a one-line
# addition to FIELDS below.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, sha256sum or shasum.
set -uo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: compacted-check.sh <console-doc> <snap-dir>" >&2
    exit 64
fi
DOC="$1"; SNAPDIR="$2"

sha_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    else shasum -a 256 | cut -d' ' -f1; fi
}

# Newest snap = highest NUMERIC n (precompact-10 outranks precompact-9).
snap=""; best=-1; f=""; n=""
if [ -d "$SNAPDIR" ]; then
    for f in "$SNAPDIR"/precompact-*.snap; do
        [ -f "$f" ] || continue
        n="${f##*/precompact-}"; n="${n%.snap}"
        case "$n" in ''|*[!0123456789]*) continue ;; esac
        if [ "$((10#$n))" -gt "$best" ]; then best="$((10#$n))"; snap="$f"; fi
    done
fi
if [ -z "$snap" ]; then
    echo "no snapshot: no precompact-<n>.snap in $SNAPDIR"
    exit 2
fi

# Line 1 = sha256=<hex of everything after line 1>.
want="$(head -n 1 "$snap")"
want="${want#sha256=}"
got="$(tail -n +2 "$snap" | sha_of)"
if [ -z "$want" ] || [ "$want" != "$got" ]; then
    echo "snapshot corrupt: $snap (sha256 line does not match its content)"
    exit 2
fi

# snap_field <key> -- value of the first `key=` line, up to the tick separator.
snap_field() {
    tail -n +2 "$snap" | awk -v k="$1" '
        $0 == "--- tick" { exit }
        index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'
}

# The last real COMPACTED bullet: a `- ` bullet naming COMPACTED with all three
# mandatory segments, so a prose bullet that merely mentions the word is never
# picked. Backticks are stripped up front.
bullet="$(grep -E '^- .*COMPACTED.* legs: .*, queue: .*, last GO: ' "$DOC" 2>/dev/null | tail -n 1 | tr -d '`')"
if [ -z "$bullet" ]; then
    echo "G11 LOSS bullet: no COMPACTED bullet found in $DOC"
    exit 1
fi

rest="${bullet#* legs: }"
b_legs="${rest%%, queue: *}"
rest="${rest#*, queue: }"
b_queue="${rest%%, last GO: *}"
rest="${rest#*, last GO: }"
b_acked=""; has_acked=0
case "$rest" in
    *", acked: "*) b_lastgo="${rest%%, acked: *}"; b_acked="${rest#*, acked: }"; has_acked=1 ;;
    *) b_lastgo="$rest" ;;
esac

trim() { local t="$1"; t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"; printf '%s' "$t"; }

rc=0
compare() {
    local field="$1" bval="$2" sval
    sval="$(snap_field "$field")"
    if [ "$(trim "$bval")" != "$(trim "$sval")" ]; then
        echo "G11 LOSS $field: snapshot=[$sval] bullet=[$bval]"
        rc=1
    fi
}
compare legs "$b_legs"
compare queue "$b_queue"
compare last-go "$b_lastgo"
[ "$has_acked" -eq 1 ] && compare acked "$b_acked"

[ "$rc" -eq 0 ] && echo "G11 ok ($(basename "$snap"))"
exit "$rc"
