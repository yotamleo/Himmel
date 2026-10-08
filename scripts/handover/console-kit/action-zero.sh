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

echo "== LOCKS (swept at the root)"
env HANDOVER_DIR="$root" bash "$ql" status --sweep "$root" 2>&1 || echo "unavailable"

echo "== HEAD"
git -C "$repo" log -1 --format=%H 2>&1 || echo "unavailable"
git -C "$repo" remote -v 2>&1 | head -n 2

echo "== BANK"
if [ -n "${ACTION_ZERO_BANK:-}" ]; then bash "$ACTION_ZERO_BANK" 2>&1 || echo "unavailable"
else bash "$repo/scripts/lib/bank-preflight.sh" 2>&1 || echo "unavailable"; fi

echo "== PROCS"
if [ -n "$prefix" ]; then pgrep -af "claude .*-n ${prefix}-" 2>/dev/null || echo "none"; else echo "skipped (no --prefix)"; fi

echo "== C29"
if [ -n "${ACTION_ZERO_DOCTOR:-}" ]; then out="$(bash "$ACTION_ZERO_DOCTOR" 2>&1)"; drc=$?
else out="$(bash "$repo/scripts/himmel-doctor.sh" 2>&1)"; drc=$?; fi
c29="$(printf '%s\n' "$out" | grep C29)"
if [ -n "$c29" ]; then printf '%s\n' "$c29"
elif [ "$drc" -ne 0 ]; then echo "unavailable (doctor exited $drc)"
else echo "none"; fi

echo "== LOAD"
uptime 2>&1 || echo "unavailable"

echo "== LOCK (this document)"
state="$(env HANDOVER_DIR="$root" bash "$ql" status "$doc" 2>&1)"
printf '%s\n' "$state"
if [ "$acquire" -eq 1 ]; then
    case "$state" in
        free*|*"free"*) env HANDOVER_DIR="$root" bash "$ql" acquire "$doc" 2>&1 ;;
        *) echo "NOT ACQUIRED — the lock is not free: find its holder, do not take it over" ;;
    esac
fi
exit 0
