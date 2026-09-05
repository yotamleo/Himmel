#!/usr/bin/env bash
# scripts/lib/watch-loop.sh -- a BOUNDED poll-loop runner (HIMMEL-1820).
#
# WHY: on 2026-08-16 a `watch-branches.sh` poll loop written into a Claude
# session's scratchpad was found still running ~10 hours after its session
# died -- fully orphaned, continuously spawning short-lived children, and a
# meaningful contributor to an unresponsive box. Scratchpad watcher loops
# have no TTL, never check whether the session they serve still exists, and
# nothing sweeps for them. The fix is not a watcher supervisor (a permanent
# process to solve permanent processes); the loops must BOUND THEMSELVES.
# Any session that wants a watch/poll loop should call this instead of
# hand-rolling `while true`.
#
# USAGE:
#   bash scripts/lib/watch-loop.sh --parent-pid <pid> \
#        [--ttl <seconds>] [--interval <seconds>] [--max-iterations <n>] \
#        -- <command...>
#
# Each iteration, in order, it stops (exit 0) when:
#   (a) elapsed wall time has reached --ttl (default 3600s);
#   (b) the iteration count has reached --max-iterations (0 = unlimited);
#   (c) `kill -0 <parent-pid>` says the parent is gone (the session that
#       spawned the watcher has exited -- stop serving a dead owner).
# Otherwise it runs <command...> once, bounded by --interval (a hung probe
# would otherwise block the loop from ever re-checking its own TTL or parent
# liveness -- bounding it by the TTL instead of --interval would still let a
# hung probe mask a dead parent for up to the whole remaining TTL, which is
# NOT "within about one interval"; exit status deliberately ignored -- a
# probe that fails is a result, not a reason to stop) and sleeps --interval,
# both capped to what's left of the TTL near expiry, before the next
# iteration.
#
# Always exits 0 when it stops itself and prints ONE reason line
# (ttl | max-iterations | parent-gone) so an operator reading a log knows
# why it stopped. Usage errors exit 2.
#
# Caveats, by design: the parent probe is `kill -0`, so the pid must be
# same-user (a foreign pid's EPERM is indistinguishable from gone), a
# REUSED pid looks alive, and an exited-but-unreaped (zombie) parent also
# looks alive -- the TTL is the backstop for all three.
#
# CONVENTIONS: bash 3.2-safe (no associative arrays, no mapfile). ASCII
# only, like scripts/lib/proc-tree.sh. No config file, no plugin surface --
# this is a guard, not a framework.
set -u

usage() {
    sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d'
}

# _wl_timeout <secs> <cmd...> -- run cmd under `timeout`, or `gtimeout`
# (macOS coreutils). Neither is guaranteed on every box this runs on, so a
# THIRD fallback (fork the probe, poll `kill -0` for up to <secs>, kill it
# if still alive) keeps the hang bound even then -- critic-panel round 2
# (codex-1, Critical) flagged the earlier "run it directly, unbounded" third
# branch as defeating the whole point of this script on such a box.
#
# `-k 1` on both timeout/gtimeout (and its manual equivalent -- a 1s grace
# after TERM, then KILL -- in the fallback) matters because plain
# `timeout $secs` only SENDS a TERM at $secs and then keeps waiting for the
# child to actually exit; a probe that ignores TERM would block `timeout`
# itself (and this whole loop) past $secs indefinitely -- critic-panel
# round 4 (codex-1, Critical) caught this. <secs> is clamped to >=1
# (round 4, codex-2, Critical): `remaining` can read 0 by the time this
# function is called (real wall-clock time elapses between the loop's own
# TTL check and here), and `timeout 0` DISABLES GNU timeout's bound
# entirely rather than firing it immediately.
#
# bash 3.2-safe: no `wait -n` (bash 4.3+), just a plain poll loop.
_wl_timeout() {
    local secs="$1"; shift
    [ "$secs" -lt 1 ] 2>/dev/null && secs=1
    if command -v timeout >/dev/null 2>&1; then timeout -k 1 "$secs" "$@"; return; fi
    if command -v gtimeout >/dev/null 2>&1; then gtimeout -k 1 "$secs" "$@"; return; fi
    "$@" &
    local cpid=$! waited=0
    while kill -0 "$cpid" 2>/dev/null; do
        if [ "$waited" -ge "$secs" ]; then
            kill "$cpid" 2>/dev/null
            sleep 1
            kill -0 "$cpid" 2>/dev/null && kill -9 "$cpid" 2>/dev/null
            wait "$cpid" 2>/dev/null
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$cpid"
}

PARENT_PID=""
TTL=3600
INTERVAL=15
MAX_ITER=0

while [ $# -gt 0 ]; do
    case "$1" in
        --parent-pid) shift; PARENT_PID="${1:-}" ;;
        --ttl) shift; TTL="${1:-}" ;;
        --interval) shift; INTERVAL="${1:-}" ;;
        --max-iterations) shift; MAX_ITER="${1:-}" ;;
        --) shift; break ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'watch-loop: unknown arg %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

for _v in PARENT_PID TTL INTERVAL; do
    case "${!_v}" in ''|*[!0-9]*) printf 'watch-loop: %s must be a positive integer (got "%s")\n' "$_v" "${!_v}" >&2; exit 2 ;; esac
    [ "${!_v}" -gt 0 ] || { printf 'watch-loop: %s must be > 0\n' "$_v" >&2; exit 2; }
done
case "$MAX_ITER" in ''|*[!0-9]*) printf 'watch-loop: --max-iterations must be a non-negative integer\n' >&2; exit 2 ;; esac
if [ $# -lt 1 ]; then
    printf 'watch-loop: no command given after --\n' >&2
    usage >&2
    exit 2
fi

# Force SECONDS to start counting from THIS point, not wherever it already
# was -- critic-panel round 6 (codex-3, Suggestion) noted that an inherited
# exported SECONDS (bash imports it from the environment like any other
# shell var) would otherwise make a freshly started watcher read as already
# partway through its TTL, expiring early.
SECONDS=0
iterations=0
reason=""
while :; do
    if [ "$SECONDS" -ge "$TTL" ]; then
        reason=ttl
        break
    fi
    if [ "$MAX_ITER" -gt 0 ] && [ "$iterations" -ge "$MAX_ITER" ]; then
        reason=max-iterations
        break
    fi
    if ! kill -0 "$PARENT_PID" 2>/dev/null; then
        reason=parent-gone
        break
    fi
    # Bound the probe to --interval, not the (much larger, default 1h) TTL --
    # critic-panel round 3 (codex-1, Important) noted that a probe bounded to
    # the remaining TTL could mask a parent's death for up to that whole
    # remaining TTL, violating the acceptance criterion (case 1 above) that
    # a dead parent is noticed within about one interval. remaining is only
    # consulted as a tighter ceiling near TTL expiry, never a looser one.
    remaining=$((TTL - SECONDS))
    probe_bound=$INTERVAL
    [ "$remaining" -lt "$probe_bound" ] && probe_bound=$remaining
    _wl_timeout "$probe_bound" "$@"
    iterations=$((iterations + 1))
    # Re-check parent liveness IMMEDIATELY after the probe, before sleeping
    # another full --interval -- critic-panel round 5 (codex-1, Important)
    # noted that without this, a parent dying mid-probe was only caught at
    # the TOP of the next iteration, after both the probe's bound AND the
    # following sleep had elapsed (~2 intervals, not "about one").
    if ! kill -0 "$PARENT_PID" 2>/dev/null; then
        reason=parent-gone
        break
    fi
    remaining=$((TTL - SECONDS))
    sleep_for=$INTERVAL
    [ "$remaining" -lt "$sleep_for" ] && sleep_for=$remaining
    [ "$sleep_for" -lt 0 ] && sleep_for=0
    sleep "$sleep_for"
done

printf 'watch-loop: exiting (%s) after %d iteration(s), %ds elapsed\n' "$reason" "$iterations" "$SECONDS"
exit 0
