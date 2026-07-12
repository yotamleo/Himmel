#!/usr/bin/env bash
# resume-slot.sh — pick the BEST relaunch slot from current usage (HIMMEL-204).
#
# arm-resume.sh's `--time auto` always returned the next cap RESET, so it
# parked the next session hours away even when the bank was wide open. That
# wastes available quota. This script makes the choice usage-AWARE:
#
#   * If every rate-limit window has headroom (utilization < --threshold),
#     relaunch ASAP — now + --buffer-min minutes (just enough for the current
#     session to /exit). Maximize throughput; don't space sessions out.
#   * If a window is at/over the threshold (effectively exhausted), wait until
#     that window resets. When several are exhausted, wait for the LATEST reset
#     (the binding constraint). A new session before then would just stall.
#
# Source: yotamleo/claude-statusline usage cache (same as cap-reset-time.sh):
#   /tmp/claude/statusline-usage-cache.json — rewritten every ~60s while a
#   claude session is live. Schema:
#     { "five_hour": { "utilization": <float %>, "resets_at": "<ISO8601 UTC>" },
#       "seven_day": { "utilization": <float %>, "resets_at": "<ISO8601 UTC>" } }
#   Schema drift (HIMMEL-732/738): newer statusline builds write resets_at as
#   a RAW EPOCH STRING like "1783760400" — both forms are accepted.
#
# Usage:
#   bash scripts/handover/resume-slot.sh                 # prints HH:MM 24h local
#   bash scripts/handover/resume-slot.sh --emit epoch    # seconds-since-epoch
#   bash scripts/handover/resume-slot.sh --emit iso      # ISO 8601 local
#   bash scripts/handover/resume-slot.sh --emit reason   # human one-liner (why)
#   bash scripts/handover/resume-slot.sh --emit all      # epoch<TAB>hhmm<TAB>reason
#
# Optional:
#   --threshold <pct>   Utilization at/above which a window counts as
#                       exhausted. Default 90.
#   --buffer-min <min>  Minutes from now for the ASAP slot. Default 4.
#   --cache <path>      Override cache path.
#   --max-age <s>       Refuse if cache older than <s>s. Default 300. 0 skips.
#
# Exit codes:
#   0  printed the chosen slot
#   1  usage / input error
#   2  cache not found OR stale (>--max-age) OR unparseable
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# python3 hang armor (HIMMEL-249): the Windows Store python3 stub can wedge
# (ignores SIGTERM, orphan child holds the $() pipe). This script sits on
# the resume-critical path — arm-resume --time smart calls it — so every
# python call goes through the shared armor.
# shellcheck source=../lib/py-armor.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/py-armor.sh"

THRESHOLD=90
BUFFER_MIN=4
CACHE_PATH="/tmp/claude/statusline-usage-cache.json"
MAX_AGE_SEC=300
EMIT=hhmm

usage() {
    cat <<'EOF'
Usage: resume-slot.sh [--threshold <pct>] [--buffer-min <min>]
                      [--cache <path>] [--max-age <s>]
                      [--emit hhmm|epoch|iso|reason|all]

Reads the claude-statusline usage cache and prints the best relaunch slot:
ASAP (now + buffer) when the bank has headroom, else the latest reset of any
exhausted window. Default emit: HH:MM 24h local.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --threshold)    THRESHOLD="${2:-}"; shift 2 ;;
        --threshold=*)  THRESHOLD="${1#--threshold=}"; shift ;;
        --buffer-min)   BUFFER_MIN="${2:-}"; shift 2 ;;
        --buffer-min=*) BUFFER_MIN="${1#--buffer-min=}"; shift ;;
        --cache)        CACHE_PATH="${2:-}"; shift 2 ;;
        --cache=*)      CACHE_PATH="${1#--cache=}"; shift ;;
        --max-age)      MAX_AGE_SEC="${2:-}"; shift 2 ;;
        --max-age=*)    MAX_AGE_SEC="${1#--max-age=}"; shift ;;
        --emit)         EMIT="${2:-}"; shift 2 ;;
        --emit=*)       EMIT="${1#--emit=}"; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "ERR resume-slot: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

case "$EMIT" in hhmm|epoch|iso|reason|all) ;; *)
    echo "ERR resume-slot: --emit must be hhmm|epoch|iso|reason|all, got: $EMIT" >&2; exit 1 ;;
esac
if ! [[ "$THRESHOLD" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "ERR resume-slot: --threshold must be numeric, got: $THRESHOLD" >&2; exit 1
fi
if ! [[ "$BUFFER_MIN" =~ ^[0-9]+$ ]]; then
    echo "ERR resume-slot: --buffer-min must be a non-negative integer, got: $BUFFER_MIN" >&2; exit 1
fi
if ! [[ "$MAX_AGE_SEC" =~ ^[0-9]+$ ]]; then
    echo "ERR resume-slot: --max-age must be a non-negative integer, got: $MAX_AGE_SEC" >&2; exit 1
fi

if [ ! -f "$CACHE_PATH" ]; then
    echo "ERR resume-slot: cache not found: $CACHE_PATH" >&2
    echo "    Open Claude Code once to populate the statusline usage cache." >&2
    exit 2
fi

# Freshness check (skip if --max-age 0). Mirrors cap-reset-time.sh.
if [ "$MAX_AGE_SEC" -gt 0 ]; then
    cache_mtime=$(py_armor_mtime "$CACHE_PATH")
    if [ -z "$cache_mtime" ]; then
        echo "ERR resume-slot: could not stat cache file: $CACHE_PATH" >&2; exit 2
    fi
    age=$(( $(date +%s) - cache_mtime ))
    if [ "$age" -gt "$MAX_AGE_SEC" ]; then
        echo "ERR resume-slot: cache stale (age ${age}s > max-age ${MAX_AGE_SEC}s)" >&2
        echo "    Statusline rewrites every ~60s during a live session. Open Claude" >&2
        echo "    Code or pass --max-age 0 to skip the freshness check." >&2
        exit 2
    fi
fi

# All the decision logic lives in one python3 block: parse the two windows,
# compare utilization (floats) to the threshold, and emit the chosen target.
# python3 is a required-env tool (HIMMEL-123); keeping ISO parsing + float
# compare + epoch math in one place avoids brittle bash float handling. The
# block OWNS its error reporting (clean ERR lines to stderr, no traceback) and
# exits 2 on any unusable-cache condition; the bash wrapper just relays the rc.
# py_armor_capture (HIMMEL-249) caps the call AND routes stdout through a
# file instead of $() — a wedged Store stub becomes a visible nonzero rc
# (124/137), never an indefinite hang of the smart resolver.
set +e
py_armor_capture - "$CACHE_PATH" "$THRESHOLD" "$BUFFER_MIN" "$EMIT" <<'PY'
import json, sys, time
from datetime import datetime, timezone

cache_path, threshold_s, buffer_s, emit = sys.argv[1:5]
threshold = float(threshold_s)
buffer_min = int(buffer_s)

def die(msg):
    sys.stderr.write("ERR resume-slot: " + msg + "\n")
    sys.exit(2)

try:
    with open(cache_path) as f:
        data = json.load(f)
except (OSError, ValueError) as e:
    die(f"cannot parse usage cache {cache_path}: {e}")
if not isinstance(data, dict):
    die("usage cache is not a JSON object")

now = time.time()
windows = ("five_hour", "seven_day")
# Schema-drift guard: a fresh-but-structurally-wrong cache (renamed/missing
# window keys) must NOT silently coerce to 0% and pick ASAP. Require at least
# one recognised window object.
if not any(isinstance(data.get(w), dict) for w in windows):
    die("usage cache has neither five_hour nor seven_day window (schema mismatch?)")

def reset_epoch(window):
    iso = (data.get(window) or {}).get("resets_at")
    if not iso:
        return None
    # Schema drift (HIMMEL-732, missed here until HIMMEL-738): newer
    # statusline builds write resets_at as a raw epoch — a bare digit string
    # like "1783760400" (or a JSON number). Mirror cap-reset-time.sh: detect
    # that form first, before the ISO 8601 path.
    if isinstance(iso, (int, float)):
        return float(iso)
    if str(iso).isdigit():
        return float(iso)
    try:
        dt = datetime.fromisoformat(iso)
    except ValueError:
        base, _, _ = iso.partition(".")
        try:
            dt = datetime.fromisoformat(base + "+00:00")
        except ValueError:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()

def util(window):
    raw = (data.get(window) or {}).get("utilization")
    if raw is None:
        die(f"{window.replace('_','-')} utilization is null — unusable signal; "
            "wait for the statusline cache to refresh or pass --time HH:MM")
    try:
        return float(raw)
    except (TypeError, ValueError):
        die(f"{window.replace('_','-')} utilization is not a number ({raw!r}) — "
            "unusable signal; wait for the statusline cache to refresh or pass --time HH:MM")

exhausted = []
for w in windows:
    if util(w) >= threshold:
        e = reset_epoch(w)
        # Exhausted but no known reset -> we cannot pick a safe wait time, and
        # scheduling ASAP would relaunch straight into a stalled window. Fail
        # loud instead of silently classifying it as headroom.
        if e is None:
            die(f"{w.replace('_','-')} exhausted ({util(w):.0f}%) but resets_at "
                "missing/unparseable -- cannot pick a safe slot; wait for the "
                "cap reset or pass --time HH:MM")
        exhausted.append((w, e))

asap = now + buffer_min * 60
if not exhausted:
    target = asap
    detail = ", ".join(f"{w.replace('_','-')}={util(w):.0f}%" for w in windows)
    reason = f"bank free ({detail} < {threshold:.0f}%) -> ASAP (+{buffer_min}m)"
else:
    # Wait for the LATEST reset among exhausted windows (binding constraint).
    w, target = max(exhausted, key=lambda t: t[1])
    # Clock-skew guard: a reset already in the past but util still high ->
    # don't schedule in the past; go ASAP and let the next arm re-evaluate.
    if target <= now:
        target = asap
        reason = f"exhausted {w.replace('_','-')} reset already passed -> ASAP (+{buffer_min}m)"
    else:
        names = ", ".join(f"{ww.replace('_','-')}={util(ww):.0f}%" for ww, _ in exhausted)
        reason = f"exhausted ({names} >= {threshold:.0f}%) -> wait for {w.replace('_','-')} reset"

target = int(round(target))
local = datetime.fromtimestamp(target).astimezone()
hhmm = local.strftime("%H:%M")
iso = local.strftime("%Y-%m-%dT%H:%M:%S%z")

if emit == "epoch":
    out = str(target)
elif emit == "iso":
    out = iso
elif emit == "reason":
    out = reason
elif emit == "all":
    out = f"{target}\t{hhmm}\t{reason}"
else:  # hhmm
    out = hhmm
sys.stdout.write(out + "\n")
PY
rc=$?
set -e
# python OWNS its diagnostics: on failure it already wrote a clean
# "ERR resume-slot: ..." line to stderr (which flows straight to the terminal,
# uncaptured), so just relay its exit code. EXCEPT rc=124/137 — the armor
# killing a wedged interpreter means python never ran far enough to report,
# so the wrapper owns that one ERR line (otherwise arm-resume's relay shows
# an empty error). On success $PY_ARMOR_OUT holds the result.
if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        echo "ERR resume-slot: python3 timed out/killed (rc=$rc — wedged interpreter?)" >&2
    fi
    exit "$rc"
fi
printf '%s\n' "$PY_ARMOR_OUT"
