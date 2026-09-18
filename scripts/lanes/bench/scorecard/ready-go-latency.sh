#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/ready-go-latency.sh - READY->GO latency and
# missed-READY measurement (HIMMEL-2975 Task 29, spec S3.5 item 5).
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+ / BSD-or-GNU date;
# it runs under git bash unchanged.
#
# Reads a console (or relay) doc for `- HH:MM READY <pr> <sha7>` and
# `- HH:MM HOLD <pr> ...` bullets and pairs each READY with its GO file
# <handover_root>/.locks/go/<pr>.<sha> (real GO files carry the full 40-char
# sha; the bullet's sha is matched as a prefix). Semantics:
#   - a READY is registered at its bullet stamp;
#   - a later READY for the same PR supersedes an earlier one (only the last
#     counts);
#   - a GO file makes the READY an event, latency = GO mtime - stamp;
#   - no GO file and a later HOLD bullet for the PR = resolved (not counted);
#   - no GO file, no HOLD, and now > stamp + 60 min = MISSED (no latency, so
#     it stays out of the median); younger than that it is simply pending.
# Bullets carry only HH:MM: the base date is the first YYYY-MM-DD in the
# doc's filename, each HH:MM is read in TZ, and the date advances one day
# whenever a bullet's HH:MM is earlier than the previous bullet's.
#
# Clock inputs: TZ, and READY_GO_NOW (epoch seconds; default `date +%s`).
#
# Usage: ready-go-latency.sh --doc <console-or-relay-doc> --since <ISO8601> [--until <ISO8601>]
# Prints: events=<n> median_min=<m> missed=<k>, then one
#         `MISSED <pr> <sha7> <HH:MM>` line per miss.
set -u

usage() { echo "usage: ready-go-latency.sh --doc <doc> [--since <ISO8601>] [--until <ISO8601>]" >&2; }

DOC=""; SINCE=""; UNTIL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --doc) DOC="${2:?--doc needs a value}"; shift 2 ;;
        --since) SINCE="${2:?--since needs a value}"; shift 2 ;;
        --until) UNTIL="${2:?--until needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ready-go-latency: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
[ -n "$DOC" ] || { usage; exit 2; }
[ -f "$DOC" ] || { echo "ready-go-latency: doc not found: $DOC" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../lib/handover-path.sh
. "$HERE/../../../lib/handover-path.sh"
ROOT=$(handover_root) || { echo "ready-go-latency: cannot resolve the handover root (set HANDOVER_DIR)" >&2; exit 2; }
GO_DIR="$ROOT/.locks/go"

# GNU `date -d` first; BSD/macOS `date -j -f` fallback (same convention as
# leg-over-by-day.sh's to_epoch).
to_epoch() {
    date -d "$1" +%s 2>/dev/null && return 0
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(printf '%s' "$1" | sed 's/\.[0-9]*Z$/Z/')" +%s 2>/dev/null
}
# <YYYY-MM-DD> <HH:MM> -> epoch, read in TZ (both date flavours honour TZ).
local_epoch() {
    date -d "$1 $2:00" +%s 2>/dev/null && return 0
    date -j -f '%Y-%m-%d %H:%M:%S' "$1 $2:00" +%s 2>/dev/null
}
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
# <YYYY-MM-DD> <n> -> the date n CALENDAR days later (not n*86400 s, so a DST
# change in between cannot skew the wall clock).
add_days() {
    date -d "$1 +$2 day" +%Y-%m-%d 2>/dev/null && return 0
    date -j -v+"$2"d -f '%Y-%m-%d' "$1" +%Y-%m-%d 2>/dev/null
}

SINCE_EPOCH=""; UNTIL_EPOCH=""
if [ -n "$SINCE" ]; then
    SINCE_EPOCH=$(to_epoch "$SINCE") || { echo "ready-go-latency: bad --since: $SINCE" >&2; exit 2; }
fi
if [ -n "$UNTIL" ]; then
    UNTIL_EPOCH=$(to_epoch "$UNTIL") || { echo "ready-go-latency: bad --until: $UNTIL" >&2; exit 2; }
fi

NOW="${READY_GO_NOW:-$(date +%s)}"
case "$NOW" in
    ''|*[!0-9]*) echo "ready-go-latency: READY_GO_NOW must be epoch seconds: $NOW" >&2; exit 2 ;;
esac

BASE_DATE=$(basename "$DOC" | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' | head -1)
[ -n "$BASE_DATE" ] || { echo "ready-go-latency: no YYYY-MM-DD in the doc filename: $DOC" >&2; exit 2; }

# One line per surviving READY: <pr> <sha> <HH:MM> <day-offset> <held 0|1>.
# Every `- HH:MM` bullet feeds the midnight-crossing check, not only READY/HOLD.
PARSED=$(awk '
    /^[ \t]*-[ \t]+[0-9][0-9]:[0-9][0-9]([ \t]|$)/ {
        line = $0
        sub(/^[ \t]*-[ \t]+/, "", line)
        stamp = substr(line, 1, 5)
        mins = substr(stamp, 1, 2) * 60 + substr(stamp, 4, 2)
        if (seen && mins < prev) day++
        prev = mins; seen = 1
        n = split(line, f, /[ \t]+/)
        kind = f[2]; pr = f[3]
        if (pr !~ /^[0-9]+$/) next
        if (kind == "READY" && n >= 4 && f[4] ~ /^[0-9a-fA-F]+$/ && length(f[4]) >= 7) {
            idx++
            last[pr] = idx
            sha[idx] = tolower(f[4]); st[idx] = stamp; dy[idx] = day; prof[idx] = pr
        } else if (kind == "HOLD") {
            idx++
            hold[pr] = idx
        }
    }
    END {
        for (i = 1; i <= idx; i++) {
            if (!(i in prof)) continue
            pr = prof[i]
            if (last[pr] != i) continue
            printf "%s %s %s %d %d\n", pr, sha[i], st[i], dy[i], ((pr in hold) && hold[pr] > i) ? 1 : 0
        }
    }
' "$DOC")

EVENTS=0; MISSED=0; LATS=""; MISSED_LINES=""
while read -r pr sha stamp day held; do
    [ -n "$pr" ] || continue
    ready_date=$(add_days "$BASE_DATE" "$day") || { echo "ready-go-latency: cannot add $day day(s) to $BASE_DATE" >&2; exit 2; }
    ready_epoch=$(local_epoch "$ready_date" "$stamp") || { echo "ready-go-latency: cannot parse $ready_date $stamp" >&2; exit 2; }
    if [ -n "$SINCE_EPOCH" ] && [ "$ready_epoch" -lt "$SINCE_EPOCH" ]; then continue; fi
    if [ -n "$UNTIL_EPOCH" ] && [ "$ready_epoch" -ge "$UNTIL_EPOCH" ]; then continue; fi

    # The bullet's sha is a prefix: two GO files behind one prefix are
    # ambiguous (refuse to guess), and a GO older than the READY stamp is a
    # stale file from an earlier round, not the answer to this READY.
    go_mtime=""; nmatch=0
    for f in "$GO_DIR/$pr.$sha"*; do
        [ -e "$f" ] || continue
        nmatch=$((nmatch + 1))
        go_mtime=$(mtime_of "$f") || go_mtime=""
    done
    if [ "$nmatch" -gt 1 ]; then
        echo "ready-go-latency: ambiguous GO prefix $pr.$sha ($nmatch files); not paired" >&2
        go_mtime=""
    elif [ -n "$go_mtime" ] && [ "$go_mtime" -lt "$ready_epoch" ]; then
        go_mtime=""
    fi

    if [ -n "$go_mtime" ]; then
        EVENTS=$((EVENTS + 1))
        LATS="$LATS$((go_mtime - ready_epoch))
"
    elif [ "$held" = 1 ]; then
        :
    elif [ "$NOW" -gt $((ready_epoch + 3600)) ]; then
        MISSED=$((MISSED + 1))
        MISSED_LINES="${MISSED_LINES}MISSED $pr $sha $stamp
"
    fi
done <<EOF
$PARSED
EOF

if [ "$EVENTS" -eq 0 ]; then
    MEDIAN="n/a"
else
    MEDIAN=$(printf '%s' "$LATS" | sort -n | awk '
        NF { v[++n] = $1 }
        END { m = (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2; printf "%g", m / 60 }')
fi
echo "events=$EVENTS median_min=$MEDIAN missed=$MISSED"
printf '%s' "$MISSED_LINES"
exit 0
