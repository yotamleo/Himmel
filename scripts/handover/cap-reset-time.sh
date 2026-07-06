#!/usr/bin/env bash
# cap-reset-time.sh — print the next claude-statusline cap-reset
# time as HH:MM 24h local. Used by arm-resume.sh's --time auto sentinel
# (HIMMEL-126) so the operator never has to guess.
#
# Source: yotamleo/claude-statusline writes a usage cache to
# /tmp/claude/statusline-usage-cache.json (60s TTL). The cache holds:
#   {
#     "five_hour": { "utilization": 20.0, "resets_at": "<ISO8601 UTC>" },
#     "seven_day": { ... },
#     ...
#   }
# We read .resets_at and convert epoch -> HH:MM local.
#
# Usage:
#   bash scripts/handover/cap-reset-time.sh                 # five-hour (default)
#   bash scripts/handover/cap-reset-time.sh --window seven-day
#   bash scripts/handover/cap-reset-time.sh --raw           # print ISO 8601 UTC verbatim
#   bash scripts/handover/cap-reset-time.sh --epoch         # print seconds-since-epoch
#
# Optional:
#   --cache <path>  Override cache path. Default: /tmp/claude/statusline-usage-cache.json.
#   --max-age <s>   Refuse if cache is older than <s> seconds. Default 300 (5min).
#                   The statusline rewrites the cache every 60s during a live
#                   session, so a cache older than 5min likely means no claude
#                   session is running. Pass 0 to skip the freshness check.
#
# Exit codes:
#   0   printed HH:MM (or --raw / --epoch)
#   1   usage / input error
#   2   cache file not found OR stale (>--max-age)
#   3   cache file present but missing the requested window's resets_at
#       (resets_at is null when the operator hasn't yet triggered the
#       rate-limit window — e.g. brand-new account, or window not active)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# python3 hang armor (HIMMEL-249): the Windows Store python3 stub can wedge
# (ignores SIGTERM, orphan child holds the $() pipe). arm-resume --time auto
# calls this script, so every python call goes through the shared armor.
# shellcheck source=../lib/py-armor.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/py-armor.sh"

WINDOW="five_hour"
CACHE_PATH="/tmp/claude/statusline-usage-cache.json"
MAX_AGE_SEC=300
OUTPUT=hhmm   # hhmm | raw | epoch

usage() {
    cat <<'EOF'
Usage: cap-reset-time.sh [--window five-hour|seven-day] [--cache <path>]
                         [--max-age <seconds>] [--raw|--epoch]

Reads the claude-statusline usage cache and prints when the requested
rate-limit window next resets, as HH:MM 24h local time (default).

Default cache: /tmp/claude/statusline-usage-cache.json (yotamleo
claude-statusline fork; 60s rewrite interval during a live session).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --window)         WINDOW="${2:-}"; shift 2 ;;
        --window=*)       WINDOW="${1#--window=}"; shift ;;
        --cache)          CACHE_PATH="${2:-}"; shift 2 ;;
        --cache=*)        CACHE_PATH="${1#--cache=}"; shift ;;
        --max-age)        MAX_AGE_SEC="${2:-}"; shift 2 ;;
        --max-age=*)      MAX_AGE_SEC="${1#--max-age=}"; shift ;;
        --raw)            OUTPUT=raw; shift ;;
        --epoch)          OUTPUT=epoch; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                echo "ERR cap-reset-time: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# Accept hyphen or underscore form ("five-hour" or "five_hour"). The
# cache uses underscores; the operator-facing flag accepts hyphens
# because shell convention.
case "$WINDOW" in
    five-hour|five_hour)   WINDOW="five_hour" ;;
    seven-day|seven_day)   WINDOW="seven_day" ;;
    *) echo "ERR cap-reset-time: --window must be five-hour or seven-day, got: $WINDOW" >&2; exit 1 ;;
esac

if ! [[ "$MAX_AGE_SEC" =~ ^[0-9]+$ ]]; then
    echo "ERR cap-reset-time: --max-age must be a non-negative integer, got: $MAX_AGE_SEC" >&2
    exit 1
fi

if [ ! -f "$CACHE_PATH" ]; then
    echo "ERR cap-reset-time: cache not found: $CACHE_PATH" >&2
    echo "    Trigger a claude-statusline render once (open Claude Code) to" >&2
    echo "    populate the cache, then re-run." >&2
    exit 2
fi

# Freshness check. Skip if --max-age 0.
if [ "$MAX_AGE_SEC" -gt 0 ]; then
    # GNU stat / BSD stat / armored-python fallback (scripts/lib/py-armor.sh).
    cache_mtime=$(py_armor_mtime "$CACHE_PATH")
    if [ -z "$cache_mtime" ]; then
        echo "ERR cap-reset-time: could not stat cache file: $CACHE_PATH" >&2
        exit 2
    fi
    now=$(date +%s)
    age=$(( now - cache_mtime ))
    if [ "$age" -gt "$MAX_AGE_SEC" ]; then
        echo "ERR cap-reset-time: cache stale (age ${age}s > max-age ${MAX_AGE_SEC}s)" >&2
        echo "    Statusline rewrites every 60s during a live session. Open Claude" >&2
        echo "    Code or pass --max-age 0 to skip the freshness check." >&2
        exit 2
    fi
fi

# Extract .resets_at via jq. Cache uses underscore keys (five_hour /
# seven_day) — already normalised above.
resets_at_iso=$(jq -r ".${WINDOW}.resets_at // \"\"" < "$CACHE_PATH" 2>/dev/null || true)
if [ -z "$resets_at_iso" ] || [ "$resets_at_iso" = "null" ]; then
    echo "ERR cap-reset-time: ${WINDOW}.resets_at is null or missing in cache" >&2
    echo "    Window may not be active for this account yet, or the cache" >&2
    echo "    schema changed. Inspect: $CACHE_PATH" >&2
    exit 3
fi

# resets_at is ISO 8601 UTC like "2026-05-25T11:40:01.173252+00:00".
# Schema drift (HIMMEL-732, observed 2026-07-06): newer statusline builds
# write resets_at as a RAW EPOCH STRING like "1783760400" for both the
# five_hour and seven_day windows. Detect that form first and use it
# directly; otherwise convert ISO -> epoch via armored python3 (portable
# across gitbash/linux/macos without GNU date -d, which BSD date lacks;
# capture goes through a file, not $(), per the HIMMEL-249 armor).
if [[ "$resets_at_iso" =~ ^[0-9]+$ ]]; then
    resets_at_epoch="$resets_at_iso"
else
py_armor_capture -c '
import sys
from datetime import datetime, timezone
s = sys.argv[1]
# fromisoformat handles ISO 8601 with +00:00 offset on python 3.11+;
# on older 3.10 strip the fractional sub-second to be safe.
try:
    dt = datetime.fromisoformat(s)
except ValueError:
    # Older python: strip fractional seconds + try again.
    base, _, _ = s.partition(".")
    dt = datetime.fromisoformat(base + "+00:00")
if dt.tzinfo is None:
    dt = dt.replace(tzinfo=timezone.utc)
print(int(dt.timestamp()))
' "$resets_at_iso" 2>/dev/null || {
    echo "ERR cap-reset-time: failed to parse resets_at: $resets_at_iso" >&2
    exit 3
}
resets_at_epoch="$PY_ARMOR_OUT"
fi

case "$OUTPUT" in
    raw)
        printf '%s\n' "$resets_at_iso"
        ;;
    epoch)
        printf '%s\n' "$resets_at_epoch"
        ;;
    hhmm)
        # Convert epoch -> HH:MM local. Armored python3 path so we don't
        # depend on GNU date -d (capture via file: this script's stdout is
        # often a caller's $() pipe — arm-resume captures it).
        py_armor_capture -c '
import sys
from datetime import datetime
epoch = int(sys.argv[1])
# .astimezone() with no arg uses the system tz.
local = datetime.fromtimestamp(epoch).astimezone()
print(local.strftime("%H:%M"))
' "$resets_at_epoch" || {
            echo "ERR cap-reset-time: failed to format epoch as HH:MM: $resets_at_epoch" >&2
            exit 3
        }
        printf '%s\n' "$PY_ARMOR_OUT"
        ;;
esac
