#!/usr/bin/env bash
# check-ci-watch.sh — the cache-backed replacement for `gh pr checks --watch
# --fail-fast` that check-ci.sh runs in its supervised background slot
# (HIMMEL-3850). Usage: check-ci-watch.sh [PR selector]
#
# `gh pr checks --watch` polls GraphQL on its own, per watcher, and cannot be
# cached. This loops over cached snapshots instead (scripts/lib/gh-ci-cache.sh),
# so N watchers on one PR cost one fetch per TTL, and it keeps gh's contract so
# check-ci's verdict logic is untouched:
#   exit 0 + "All checks were successful"   no check pending, none failed
#   exit 1 + "X <name>" lines on STDOUT      a check failed (fail-fast: others may still run)
#   exit 1 + text on STDERR                  the checks could not be read (check-ci maps it to exit 2)
# check-ci re-confirms a red structurally itself, and a green is re-read here with
# the tight "decide" TTL, so a verdict is never older than a few seconds.
#
# Adaptive interval: starts at CHECK_CI_WATCH_INTERVAL (floor, default 30 s) and
# doubles while the rollup is unchanged, up to CHECK_CI_WATCH_INTERVAL_MAX
# (ceiling, default 120 s); any change resets it to the floor.
#
# Env: CHECK_CI_CACHE_TTL (60), CHECK_CI_DECIDE_TTL (5), CHECK_CI_WATCH_INTERVAL,
#      CHECK_CI_WATCH_INTERVAL_MAX, CHECK_CI_CACHE_HEAD (the head check-ci already
#      read — saves a call), CHECK_CI_MAX_WAIT (bound on a budget wait),
#      CHECK_CI_WATCH_SLEEP_CMD (test seam; default a TERM-interruptible real sleep),
#      plus every knob in scripts/lib/gh-ci-cache.sh.
#
# A `cancel` bucket is neither red nor pending, exactly as gh's own counts treat it
# (only `fail` exits 1, only `pending` keeps the watch running): a cancelled
# REQUIRED check is refused downstream by check-ci's required-check gate, so the
# decision is the legacy one. ponytail: this mirrors gh's classification as
# remembered from its source, not a live probe of it — re-check on a gh major bump.
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

SLEEP_PID=""
# A real sleep runs in the background and is waited on, so the TERM check-ci sends
# when it stops the watch runs this trap at once instead of after the sleep.
_hsleep() {
    if [ -n "${CHECK_CI_WATCH_SLEEP_CMD:-}" ]; then "$CHECK_CI_WATCH_SLEEP_CMD" "$1"; return 0; fi
    sleep "$1" & SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null
    SLEEP_PID=""
}
CIC_SLEEP_CMD=_hsleep
trap '[ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null; cic_unlock; exit 143' TERM INT
trap 'cic_unlock' EXIT

selector="${1:-}"
if ! cic_init "$selector" "${CHECK_CI_CACHE_HEAD:-}"; then
    echo "check-ci-watch: cannot bind the PR head (or the cache dir) — cannot watch" >&2
    exit 1
fi

# _classify — sets FAILS / PENDING counts from CIC_ROWS.
_classify() {
    FAILS=$(printf '%s\n' "$CIC_ROWS" | awk -F'\t' '$1 == "fail" { c++ } END { print c + 0 }')
    PENDING=$(printf '%s\n' "$CIC_ROWS" | awk -F'\t' '$1 != "pass" && $1 != "skipping" && $1 != "fail" && $1 != "cancel" { c++ } END { print c + 0 }')
}

# _read <ttl> — one cached read; a failure ends the watch the way gh's would.
_read() {
    cic_get "$1"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "check-ci-watch: ${CIC_ERR:-cannot read the checks}" >&2
        exit 1
    fi
    if [ -z "$CIC_ROWS" ]; then
        echo "check-ci-watch: no checks reported" >&2
        exit 1
    fi
}

interval=$FLOOR
last_sig=""
while :; do
    _read "$TTL"
    _classify
    if [ "$FAILS" -gt 0 ] || [ "$PENDING" -eq 0 ]; then
        # A verdict: confirm on a fresh snapshot before ending the watch.
        _read "$DTTL"
        _classify
        if [ "$FAILS" -gt 0 ]; then
            printf '%s\n' "$CIC_ROWS" | awk -F'\t' '$1 == "fail" { print "X\t" $2 }'
            exit 1
        fi
        if [ "$PENDING" -eq 0 ]; then
            echo "All checks were successful"
            exit 0
        fi
    fi
    sig=$(printf '%s\n' "$CIC_ROWS" | cksum)
    if [ -n "$last_sig" ] && [ "$sig" = "$last_sig" ]; then
        interval=$((interval * 2))
        [ "$interval" -gt "$CEIL" ] && interval=$CEIL
    else
        interval=$FLOOR
    fi
    last_sig="$sig"
    _hsleep "$interval"
done
