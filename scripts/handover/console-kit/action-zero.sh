#!/usr/bin/env bash
# action-zero.sh — HIMMEL-4902. The incoming console's mechanical ACTION ZERO
# probes (console-template.md steps 2-6 and 8) in ONE command that prints one
# summary, instead of six or seven Bash turns that each re-read the context.
#
#   action-zero.sh --doc <this console doc> --root <handover root> [--repo <path>]
#                  [--prefix <P>] [--acquire]
#
#   LOCKS   queue-lock.sh status --sweep at the ROOT (never the bucket)
#   HEAD    primary head sha + remote
#   BANK    bank-preflight.sh output
#   PROCS   the leg processes (pgrep -af 'claude .*-n <prefix>-')
#   C29     himmel-doctor.sh C29 lines (a session that inherited CHILD_SESSION=1)
#   LOAD    uptime
#   LOCK    this document's lock state; with --acquire and state `free`, acquires
#           it and prints the release token. `held` is never taken over.
#
# Everything is read-only except --acquire. What it leaves to the console, on
# purpose (they need its own turn and its own authority): ListAgents (step 1),
# the relays and each leg's quote-back (step 9), sending LIVE, and starting the
# waiter (step 10). A section that fails prints `unavailable` and the rest run.
#
# Seams (tests): ACTION_ZERO_BANK, ACTION_ZERO_DOCTOR replace those commands.
# HIMMEL-4919: BANK and C29 run under a timeout (ACTION_ZERO_BANK_TIMEOUT,
# default 60s; ACTION_ZERO_DOCTOR_TIMEOUT, default 120s). A hung probe prints
# `TIMEOUT <bank|doctor> after <n>s` in its section and the summary carries on.
# No timeout binary: the probes run unbounded, with a WARN line.
# Exit: 0; 2 usage. PLATFORM GUARD: Linux-only kit, bash 3.2-safe.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$HERE/../../.." && pwd)"
doc=""; root=""; prefix=""; acquire=0
usage() { echo "usage: action-zero.sh --doc <console doc> --root <handover root> [--repo <path>] [--prefix <P>] [--acquire]" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc) [ "$#" -ge 2 ] || usage; doc="$2"; shift 2 ;;
        --root) [ "$#" -ge 2 ] || usage; root="$2"; shift 2 ;;
        --repo) [ "$#" -ge 2 ] || usage; repo="$2"; shift 2 ;;
        --prefix) [ "$#" -ge 2 ] || usage; prefix="$2"; shift 2 ;;
        --acquire) acquire=1; shift ;;
        *) usage ;;
    esac
done
if [ -z "$doc" ] || [ -z "$root" ]; then usage; fi
ql="$repo/scripts/handover/queue-lock.sh"

# shellcheck source=../../lib/timeout-bin.sh
. "$repo/scripts/lib/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""
bank_t="${ACTION_ZERO_BANK_TIMEOUT:-60}"; doctor_t="${ACTION_ZERO_DOCTOR_TIMEOUT:-120}"
# bounded <name> <secs> <cmd...>: output on stdout; a timeout prints the TIMEOUT line.
bounded() {
    local name="$1" secs="$2" brc; shift 2
    if [ -z "${_TIMEOUT_BIN:-}" ]; then
        echo "WARN no timeout binary: $name probe runs unbounded"
        "$@" 2>&1; return $?
    fi
    "$_TIMEOUT_BIN" -k 2 "$secs" "$@" 2>&1; brc=$?
    if [ "$brc" -eq 124 ] || [ "$brc" -eq 137 ]; then echo "TIMEOUT $name after ${secs}s"; fi
    return "$brc"
}

echo "== LOCKS (swept at the root)"
env HANDOVER_DIR="$root" bash "$ql" status --sweep "$root" 2>&1 || echo "unavailable"

echo "== HEAD"
git -C "$repo" log -1 --format=%H 2>&1 || echo "unavailable"
git -C "$repo" remote -v 2>&1 | head -n 2

echo "== BANK"
bank_cmd="${ACTION_ZERO_BANK:-$repo/scripts/lib/bank-preflight.sh}"
bout="$(bounded bank "$bank_t" bash "$bank_cmd")"; brc=$?
printf '%s\n' "$bout"
if [ "$brc" -ne 0 ] && ! printf '%s\n' "$bout" | grep -q '^TIMEOUT bank'; then echo "unavailable"; fi

echo "== PROCS"
if [ -n "$prefix" ]; then pgrep -af "claude .*-n ${prefix}-" 2>/dev/null || echo "none"; else echo "skipped (no --prefix)"; fi

echo "== C29"
doctor_cmd="${ACTION_ZERO_DOCTOR:-$repo/scripts/himmel-doctor.sh}"
out="$(bounded doctor "$doctor_t" bash "$doctor_cmd")"; drc=$?
c29="$(printf '%s\n' "$out" | grep -E 'C29|^TIMEOUT doctor|^WARN no timeout')"
if [ -n "$c29" ]; then printf '%s\n' "$c29"
elif [ "$drc" -ne 0 ]; then echo "unavailable (doctor exited $drc)"
else echo "none"; fi

echo "== LOAD"
uptime 2>&1 || echo "unavailable"

echo "== LOCK (this document)"
state="$(env HANDOVER_DIR="$root" bash "$ql" status "$doc" 2>&1)"; src=$?
printf '%s\n' "$state"
if [ "$acquire" -eq 1 ]; then
    if [ "$src" -eq 0 ] && [ "$state" = free ]; then
        env HANDOVER_DIR="$root" bash "$ql" acquire "$doc" 2>&1
    else
        echo "NOT ACQUIRED — the lock is not free: find its holder, do not take it over"
    fi
fi
exit 0
