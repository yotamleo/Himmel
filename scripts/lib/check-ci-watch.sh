#!/usr/bin/env bash
# check-ci-watch.sh — cache-backed PR watch (HIMMEL-3850) and foreground
# workflow/job watch (HIMMEL-4856). Both share one adaptive backoff.
# Usage: check-ci-watch.sh [PR selector]
#        check-ci-watch.sh --run <id> <job-name-or-empty> <max-wait>
# PR contract: 0 + success text; 1 + X rows on red, stderr on unreadable.
# Run contract: 0 success; 1 red/cancelled; 2 unreadable/deadline (7 opt-in).
# Env: CHECK_CI_CACHE_TTL (60), CHECK_CI_DECIDE_TTL (5),
# CHECK_CI_WATCH_INTERVAL (30), CHECK_CI_WATCH_INTERVAL_MAX (120),
# CHECK_CI_WATCH_SLEEP_CMD (test seam), CHECK_CI_RUN_HEARTBEAT (optional path),
# plus gh-ci-cache.sh knobs. Run heartbeat uses console-wait.sh's shape.
# PR cancel remains neither red nor pending (the required-check gate handles
# cancellation); run cancellation cannot certify success and is red.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/gh-ci-cache.sh
# shellcheck disable=SC1091
. "$HERE/gh-ci-cache.sh"

_num() { case "$2" in ''|*[!0-9]*|0) echo "$3" ;; *) echo "$2" ;; esac; }
FLOOR=$(_num floor "${CHECK_CI_WATCH_INTERVAL:-30}" 30)
CEIL=$(_num ceil "${CHECK_CI_WATCH_INTERVAL_MAX:-120}" 120)
[ "$CEIL" -lt "$FLOOR" ] && CEIL=$FLOOR
TTL=$(_num ttl "${CHECK_CI_CACHE_TTL:-60}" 60)
DTTL=$(_num dttl "${CHECK_CI_DECIDE_TTL:-5}" 5)
export CIC_MAX_WAIT="${CIC_MAX_WAIT:-${CHECK_CI_MAX_WAIT:-0}}"

RUN_MODE=0; JOB_NAME=""; MAX_WAIT=0; HB_FILE=""; TICK="-"
SLEEP_PID=""
_hsleep() {
    if [ -n "${CHECK_CI_WATCH_SLEEP_CMD:-}" ]; then "$CHECK_CI_WATCH_SLEEP_CMD" "$1"; return 0; fi
    sleep "$1" & SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null
    SLEEP_PID=""
}
CIC_SLEEP_CMD=_hsleep
_heartbeat() {
    [ -n "$HB_FILE" ] || return 0
    local line
    line="hb=$(date +%s) pid=$$ key=${CIC_HEAD:--} tick=$TICK state=$1"
    [ -n "${2:-}" ] && line="$line exit=$2"
    printf '%s\n' "$line" > "$HB_FILE.$$.tmp" && mv -f "$HB_FILE.$$.tmp" "$HB_FILE"
}
_finish() { local rc=$?; cic_unlock; _heartbeat exited "$rc"; }
trap '[ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null; exit 143' TERM INT
trap _finish EXIT

if [ "${1:-}" = --run ]; then
    RUN_MODE=1; JOB_NAME="${3:-}"; MAX_WAIT="${4:-900}"
    if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        echo "check-ci: run mode requires gh and jq" >&2; exit 2
    fi
    # shellcheck source=scripts/lib/timeout-bin.sh
    # shellcheck disable=SC1091
    . "$HERE/timeout-bin.sh"
    if [ "$MAX_WAIT" -gt 0 ] && [ -z "$_TIMEOUT_BIN" ]; then
        echo "check-ci: cannot bound run reads without timeout/gtimeout" >&2; exit 2
    fi
    CIC_DEADLINE=0
    [ "$MAX_WAIT" -eq 0 ] || CIC_DEADLINE=$((SECONDS + MAX_WAIT))
    START=$(cic_now)
    if ! cic_init_run "$2"; then echo "check-ci: cannot bind workflow run/cache" >&2; exit 2; fi
    HB_FILE="${CHECK_CI_RUN_HEARTBEAT:-$CIC_FILE.$$.wait}"
    echo "check-ci: waiting on run $CIC_RUN_ID${JOB_NAME:+ job $JOB_NAME}; heartbeat=$HB_FILE"
    _heartbeat sampling || { echo "check-ci: cannot write heartbeat" >&2; exit 2; }
else
    if ! cic_init "${1:-}" "${CHECK_CI_CACHE_HEAD:-}"; then
        echo "check-ci-watch: cannot bind the PR head (or the cache dir) — cannot watch" >&2
        exit 1
    fi
fi

# Run mode filters after the shared read: job and whole-run waiters use the
# same cache entry. A selected job not yet registered is pending, unless the
# workflow has already completed (then the selector cannot be evaluated).
_classify() {
    ROWS="$CIC_ROWS"
    if [ "$RUN_MODE" = 1 ] && [ -n "$JOB_NAME" ]; then
        ROWS=$(printf '%s\n' "$CIC_ROWS" | CHECK_CI_JOB_NAME="$JOB_NAME" awk -F'\t' '$3 == "job" && $2 == ENVIRON["CHECK_CI_JOB_NAME"]')
        if [ -z "$ROWS" ]; then
            if [ "$(printf '%s\n' "$CIC_ROWS" | awk -F'\t' '$3 == "run" {print $1}')" != pending ]; then
                echo "check-ci: job '$JOB_NAME' not found in completed run $CIC_RUN_ID" >&2; exit 2
            fi
            ROWS=$'pending\tjob not registered'
        fi
    fi
    FAILS=$(printf '%s\n' "$ROWS" | awk -F'\t' '$1 == "fail" { c++ } END { print c + 0 }')
    PENDING=$(printf '%s\n' "$ROWS" | awk -F'\t' '$1 != "pass" && $1 != "skipping" && $1 != "fail" && $1 != "cancel" { c++ } END { print c + 0 }')
}

_read() {
    if [ "$RUN_MODE" = 1 ]; then
        _heartbeat sampling || exit 2
        if [ "$MAX_WAIT" -gt 0 ]; then
            CIC_MAX_WAIT=$((MAX_WAIT - ($(cic_now) - START)))
            if [ "$CIC_MAX_WAIT" -le 0 ]; then _deadline; fi
        fi
    fi
    cic_get "$1"
    local rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$CIC_ROWS" ]; then
        if [ "$RUN_MODE" = 1 ] && [ "${CIC_DEADLINE_HIT:-0}" = 1 ] && [ "${PENDING:-0}" -gt 0 ]; then _deadline; fi
        TICK=fail
        echo "check-ci-watch: ${CIC_ERR:-no checks reported}" >&2
        [ "$RUN_MODE" = 0 ] && exit 1
        exit 2
    fi
    TICK=ok
}
_deadline() {
    echo "check-ci: DEADLINE-PENDING run $CIC_RUN_ID after ${MAX_WAIT}s"
    [ "${CHECK_CI_DISTINCT_DEADLINE:-0}" = 1 ] && exit 7
    exit 2
}

interval=$FLOOR
last_sig=""
while :; do
    _read "$TTL"
    _classify
    if [ "$FAILS" -gt 0 ] || [ "$PENDING" -eq 0 ]; then
        _read "$DTTL"
        _classify
        if [ "$FAILS" -gt 0 ]; then
            printf '%s\n' "$ROWS" | awk -F'\t' '$1 == "fail" { print "X\t" $2 }'
            if [ "$RUN_MODE" = 1 ]; then echo "check-ci: logs: gh run view $CIC_RUN_ID --log-failed --repo $CIC_RUN_REPO"; fi
            exit 1
        fi
        if [ "$PENDING" -eq 0 ]; then
            echo "All checks were successful"
            exit 0
        fi
    fi
    sig=$(printf '%s\n' "$ROWS" | cksum)
    if [ -n "$last_sig" ] && [ "$sig" = "$last_sig" ]; then
        interval=$((interval * 2))
        [ "$interval" -gt "$CEIL" ] && interval=$CEIL
    else
        interval=$FLOOR
    fi
    last_sig="$sig"
    sleep_for=$interval
    if [ "$RUN_MODE" = 1 ]; then
        if [ "$MAX_WAIT" -gt 0 ]; then
            left=$((MAX_WAIT - ($(cic_now) - START)))
            [ "$left" -gt 0 ] || _deadline
            [ "$sleep_for" -le "$left" ] || sleep_for=$left
        fi
        _heartbeat waiting || exit 2
    fi
    _hsleep "$sleep_for"
done
