#!/usr/bin/env bash
# Tests for scripts/lib/gh-graphql-budget.sh and its check-ci.sh wiring
# (HIMMEL-3190 — CI watchers exhausted the GitHub GraphQL budget fleet-wide).
#
# Hermetic: `gh` is a PATH stub that records every call (fake-clock stamp +
# GraphQL points it would cost) and fakes the X-Ratelimit-* headers of a real
# `gh api -i graphql` call. Never talks to GitHub.
#
# The wall clock is FAKE: check-ci.sh's every wait goes through
# CHECK_CI_SLEEP_CMD, and the seam here is an exported bash FUNCTION that
# advances $SECONDS inside check-ci's own shell, so a simulated hour costs
# milliseconds and the throttle is proven at its SHIPPED DEFAULTS (no
# CHECK_CI_POLL_INTERVAL / CHECK_CI_WATCH_INTERVAL / CHECK_CI_PROBE_INTERVAL
# override anywhere in the rate case).
#
# Real-API measurement this suite encodes (PR 859, 7 pending checks,
# GH_DEBUG=api, 2026-09-19): one `gh pr checks` resolve = 3 GraphQL POSTs, each
# poll/probe = +1 status query; `gh pr checks --json` = 4 POSTs; the OLD loop
# probed every 10 s and `gh pr checks --watch` polled every 10 s, so ~30
# POSTs/minute per watcher. The budget for the new path is <= 1/4 of that.
#
# Cases:
#   1.  steady-state rate at defaults: <= 7.5 GraphQL calls / simulated minute
#   2.  exhausted budget at start, reset inside --max-wait: sleeps until the
#       reset (+ jitter, same seam), then the run finishes green rc 0
#   3.  exhausted budget, reset beyond --max-wait: rc 2, says so, never starts
#       a watch
#   4.  mid-watch "rate limit exceeded" from gh: waits for the reset, retries
#       the round, rc 0 (not exit 2)
#   5.  rate limit on the grace probe: waits, retries, rc 0
#   6.  review-thread query fails while the budget is exhausted: waits, retries
#   7.  helper unit cases (floor edge, unparsable headers, opt-out, jitter
#       range, jitter clamped to the bound, no waits when budget is healthy)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/gh-graphql-budget.sh"
CHECK_CI="$SCRIPT_DIR/../check-ci.sh"
# shellcheck source=scripts/lib/timeout-bin.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/timeout-bin.sh"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gh-graphql-budget.XXXXXX") ||{ echo "FATAL: mktemp -d failed"; exit 1; }
[ -d "$ROOT" ] || { echo "FATAL: no temp dir"; exit 1; }
# shellcheck disable=SC2329,SC2317
cleanup() { if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then rm -rf "$ROOT" 2>/dev/null; fi; return 0; }
trap cleanup EXIT

BIN="$ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
# gh stub for test-gh-graphql-budget.sh. State dir: $GHB_STUB_DIR.
#   clock       — fake seconds (written by the sleep seam)
#   exhausted   — presence = budget exhausted until $D/woke exists; content = reset epoch
#   calls.log   — "<fake-clock> <graphql-points> <args...>", one line per call
D="$GHB_STUB_DIR"
clock=$(cat "$D/clock" 2>/dev/null); clock=${clock:-0}
log() { local pts="$1"; shift; echo "$clock $pts $*" >> "$D/calls.log"; }
exhaust() { echo "$(( $(date +%s) + ${1:-60} ))" > "$D/exhausted"; rm -f "$D/woke"; }
if [ -f "$D/exhausted" ] && [ ! -f "$D/woke" ]; then
    rem=0; rst=$(cat "$D/exhausted")
else
    rem=${GHB_STUB_REMAINING:-5000}; rst=$(( $(date +%s) + 3000 ))
fi
cmd="${1:-}"
if [ "$cmd" = "api" ]; then
    case " $* " in
        *" -i "*)
            log 0 "$@"
            if [ "${GHB_STUB_NOHEADERS:-0}" = 1 ]; then echo '{"data":{}}'; exit 0; fi
            printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: %s\r\nX-Ratelimit-Reset: %s\r\n\r\n{"data":{}}\n' "$rem" "$rst"
            [ "$rem" -gt 0 ] || exit 1
            exit 0 ;;
        *graphql*)
            log 1 "$@"
            if [ "${GHB_STUB_MODE:-}" = thread-fail-once ] && [ ! -f "$D/threadfailed" ]; then
                touch "$D/threadfailed"; exhaust 60
                echo "HTTP 403: API rate limit exceeded" >&2; exit 1
            fi
            echo "0 false null"; exit 0 ;;
        # HIMMEL-3381: the required-set reads (--jq is ignored by this stub, so emit
        # the post-jq shape: no required contexts).
        *rules/branches*|*protection/required_status_checks*) log 0 "$@"; exit 0 ;;
        *) log 0 "$@"; echo '[]'; exit 0 ;;
    esac
fi
if [ "$cmd" = "pr" ] && [ "${2:-}" = "view" ]; then
    log 1 "$@"
    case " $* " in
        *mergeStateStatus*) echo "sha1 CLEAN" ;;   # HIMMEL-3473: GitHub's verdict, parsed shape
        *headRefOid*)  echo sha1 ;;
        *author,files*) printf 'MPR_OK\noctocat\nfalse\n1\nREADME.md\n' ;;
        *)             echo "https://github.com/octo/demo/pull/42|null" ;;
    esac
    exit 0
fi
# gh pr checks ...
case " $* " in
    *" --watch "*)
        log 3 "$@"
        case "${GHB_STUB_MODE:-}" in
            block) exec sleep 120 ;;
            rl-watch-once)
                if [ ! -f "$D/rlfired" ]; then
                    touch "$D/rlfired"; exhaust 60
                    echo "GraphQL: API rate limit already exceeded for user ID 1." >&2; exit 1
                fi
                echo "All checks were successful"; exit 0 ;;
            *) echo "All checks were successful"; exit 0 ;;
        esac ;;
    *" --json "*)
        log 4 "$@"
        case " $* " in
            *length*)        printf '1\nunit-tests\n' ;;
            *bucket,name*)   printf 'CHECKCI_OK\nunit-tests\n' ;;
            *)               echo 0 ;;
        esac
        exit 0 ;;
    *)
        log 4 "$@"
        if [ "${GHB_STUB_MODE:-}" = rl-grace-once ] && [ ! -f "$D/rlfired" ]; then
            touch "$D/rlfired"; exhaust 60
            echo "GraphQL: API rate limit already exceeded for user ID 1." >&2; exit 1
        fi
        exit 8 ;;
esac
EOF
chmod +x "$BIN/gh" || { echo "FATAL: chmod gh stub"; exit 1; }

# The fake clock. An exported FUNCTION, so check-ci.sh's `"$CHECK_CI_SLEEP_CMD" n`
# runs it in check-ci's own shell and $SECONDS really jumps. A sleep >= 30 s is a
# budget wait (the loops only sleep 10 s), and only that "wakes" the stub past
# its reset.
fakesleep() {
    SECONDS=$((SECONDS + ${1:-0}))
    echo "$SECONDS" > "$GHB_STUB_DIR/clock"
    echo "${1:-0}" >> "$GHB_STUB_DIR/sleeps.log"
    [ "${1:-0}" -ge 30 ] && touch "$GHB_STUB_DIR/woke"
    return 0
}
export -f fakesleep

new_case() {
    CASE_DIR=$(mktemp -d "$ROOT/case.XXXXXX") || { echo "FATAL: mktemp case"; exit 1; }
    : > "$CASE_DIR/calls.log"; : > "$CASE_DIR/sleeps.log"; echo 0 > "$CASE_DIR/clock"
    mkdir -p "$CASE_DIR/cwd"
}

# run_ci <stub-mode> <check-ci args...>  — knobs a case wants go in the caller's
# env via `env`-style prefixes on the function call site (see below).
RC=0; ERR=""
run_ci() {
    local mode="$1"; shift
    ( cd "$CASE_DIR/cwd" && \
      PATH="$BIN:$PATH" GHB_STUB_DIR="$CASE_DIR" GHB_STUB_MODE="$mode" \
      CHECK_CI_SLEEP_CMD=fakesleep CHECK_CI_SETTLE=0 CR_APP=0 CR_PROFILE=none \
      ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 240} bash "$CHECK_CI" "$@" >"$CASE_DIR/out" 2>"$CASE_DIR/err" )
    RC=$?
    ERR=$(cat "$CASE_DIR/err")
}

echo "test-gh-graphql-budget.sh"

# 1 — steady-state GraphQL rate at the SHIPPED defaults.
# One long `block` watch, 3600 fake seconds. Window [60,3540) excludes the
# resolve/setup at the start and the cap tail, so it is the steady state.
new_case
run_ci block 42 --max-wait 3600
pts=$(awk '$1>=60 && $1<3540 {s+=$2} END{print s+0}' "$CASE_DIR/calls.log")
interval=$(grep -- '--watch' "$CASE_DIR/calls.log" | head -1 | sed -n 's/.*--interval \([0-9][0-9]*\).*/\1/p')
interval=${interval:-10}            # gh's own default when check-ci passes none
watch_polls=$(( (3540 - 60) / interval ))
rate_x100=$(( (pts + watch_polls) * 100 / 58 ))
echo "  measured: probes=${pts} watch_polls=${watch_polls} (interval=${interval}s) over 58 min => $((rate_x100 / 100)).$(printf '%02d' $((rate_x100 % 100))) GraphQL calls/min (old path: ~30)"
if [ "$rate_x100" -le 750 ]; then pass "1 steady-state <= 7.5 calls/min (1/4 of the measured 30)"; else fail "1 steady-state rate" "got ${rate_x100}/100 calls/min, want <= 750/100"; fi
if [ "$RC" -eq 2 ]; then pass "1b rc 2 unchanged for a cap-with-pending verdict"; else fail "1b rc" "rc=$RC want 2 (err: $ERR)"; fi

# 2 — budget exhausted at start, reset inside --max-wait.
new_case
echo "$(( $(date +%s) + 90 ))" > "$CASE_DIR/exhausted"
run_ci green 42 --max-wait 900
biggest=$(sort -n "$CASE_DIR/sleeps.log" | tail -1)
if [ "${biggest:-0}" -ge 90 ] 2>/dev/null; then pass "2 slept until the reset (${biggest}s)"; else fail "2 sleep to reset" "sleeps: $(tr '\n' ' ' <"$CASE_DIR/sleeps.log") (want a >=90 s wait)"; fi
if [ "$RC" -eq 0 ]; then pass "2b run finishes green rc 0 after the wait"; else fail "2b rc" "rc=$RC err=$ERR"; fi
too_long=$(awk '$1>92+15 {c++} END{print c+0}' "$CASE_DIR/sleeps.log")
if [ "$too_long" -eq 0 ]; then pass "2c wait + jitter stays within reset+2s+15s"; else fail "2c bound" "sleeps: $(tr '\n' ' ' <"$CASE_DIR/sleeps.log")"; fi
if grep -q -- '--watch' "$CASE_DIR/calls.log"; then pass "2d the watch ran only after the wait"; else fail "2d watch ran" "no --watch call logged"; fi

# 3 — exhausted, reset beyond the caller's --max-wait.
new_case
echo "$(( $(date +%s) + 1000 ))" > "$CASE_DIR/exhausted"
run_ci green 42 --max-wait 60
if [ "$RC" -eq 2 ]; then pass "3 rc 2 (cannot evaluate), meaning unchanged"; else fail "3 rc" "rc=$RC want 2"; fi
if printf '%s' "$ERR" | grep -qi 'budget exhausted'; then pass "3b says the budget is exhausted"; else fail "3b message" "stderr: $ERR"; fi
if ! grep -q -- '--watch' "$CASE_DIR/calls.log"; then pass "3c no watch started"; else fail "3c watch" "a --watch call was made"; fi

# 4 — rate limit reported by gh mid-watch: wait for the reset, retry, not exit 2.
new_case
run_ci rl-watch-once 42 --max-wait 900
biggest=$(sort -n "$CASE_DIR/sleeps.log" | tail -1)
if [ "$RC" -eq 0 ]; then pass "4 mid-watch rate limit -> waited and finished rc 0"; else fail "4 rc" "rc=$RC err=$ERR"; fi
if [ "${biggest:-0}" -ge 30 ] 2>/dev/null; then pass "4b slept toward the reset (${biggest}s)"; else fail "4b sleep" "sleeps: $(tr '\n' ' ' <"$CASE_DIR/sleeps.log")"; fi

# 5 — rate limit on the grace-window probe.
new_case
run_ci rl-grace-once 42 --max-wait 900
biggest=$(sort -n "$CASE_DIR/sleeps.log" | tail -1)
if [ "$RC" -eq 0 ]; then pass "5 grace-probe rate limit -> waited and finished rc 0"; else fail "5 rc" "rc=$RC err=$ERR"; fi
if [ "${biggest:-0}" -ge 30 ] 2>/dev/null; then pass "5b slept toward the reset (${biggest}s)"; else fail "5b sleep" "sleeps: $(tr '\n' ' ' <"$CASE_DIR/sleeps.log")"; fi

# 6 — the review-thread query fails while the budget is exhausted.
new_case
run_ci thread-fail-once 42 --max-wait 900
biggest=$(sort -n "$CASE_DIR/sleeps.log" | tail -1)
if [ "$RC" -eq 0 ]; then pass "6 thread-query failure on an exhausted budget -> waited, retried, rc 0"; else fail "6 rc" "rc=$RC err=$ERR"; fi
if [ "${biggest:-0}" -ge 30 ] 2>/dev/null; then pass "6b slept toward the reset (${biggest}s)"; else fail "6b sleep" "sleeps: $(tr '\n' ' ' <"$CASE_DIR/sleeps.log")"; fi

# 7 — helper unit cases, in-process against the same stub.
if [ ! -f "$LIB" ]; then
    fail "7 helper file exists" "$LIB is missing"
else
    # shellcheck source=scripts/lib/gh-graphql-budget.sh
    . "$LIB"
    rec_sleep() { echo "$1" >> "$CASE_DIR/unit-sleeps.log"; }
    unit() {   # unit <max_wait> — runs the helper against the stub in CASE_DIR
        : > "$CASE_DIR/unit-sleeps.log"
        PATH="$BIN:$PATH" GHB_STUB_DIR="$CASE_DIR" ghb_wait_for_budget "$1" rec_sleep
    }

    new_case
    GHB_STUB_REMAINING=5000 unit 900; rc=$?
    if [ "$rc" -eq 0 ] && [ ! -s "$CASE_DIR/unit-sleeps.log" ] && [ "$GHB_WAITED" -eq 0 ]; then pass "7a healthy budget: rc 0, no sleep, GHB_WAITED=0"; else fail "7a healthy" "rc=$rc sleeps=$(cat "$CASE_DIR/unit-sleeps.log")"; fi
    calls=$(grep -c -- '-i' "$CASE_DIR/calls.log"); if [ "$calls" -eq 1 ]; then pass "7b exactly ONE preflight call"; else fail "7b call count" "$calls preflight calls"; fi

    new_case
    export GHB_STUB_REMAINING=200; unit 900; rc=$?
    if [ "$rc" -eq 0 ] && [ ! -s "$CASE_DIR/unit-sleeps.log" ]; then pass "7c remaining == floor (200): no wait"; else fail "7c floor edge" "rc=$rc"; fi
    unset GHB_STUB_REMAINING
    echo "$(( $(date +%s) + 40 ))" > "$CASE_DIR/exhausted"
    unit 900; rc=$?
    if [ "$rc" -eq 0 ] && [ "$GHB_WAITED" -eq 1 ] && [ -s "$CASE_DIR/unit-sleeps.log" ]; then pass "7d exhausted: waited (GHB_WAITED=1)"; else fail "7d exhausted" "rc=$rc waited=$GHB_WAITED"; fi

    new_case
    GHB_STUB_NOHEADERS=1 unit 900; rc=$?
    if [ "$rc" -eq 0 ] && [ ! -s "$CASE_DIR/unit-sleeps.log" ]; then pass "7e unparsable headers: proceed, no sleep (fail-open preflight only)"; else fail "7e unparsable" "rc=$rc"; fi

    new_case
    GH_BUDGET_PREFLIGHT=0 unit 900; rc=$?
    if [ "$rc" -eq 0 ] && [ ! -s "$CASE_DIR/calls.log" ]; then pass "7f GH_BUDGET_PREFLIGHT=0 makes no call"; else fail "7f opt-out" "rc=$rc calls=$(wc -l <"$CASE_DIR/calls.log")"; fi

    # jitter: wake-up spread over 0..15 s, drawn per call; 30 draws must stay in range
    # and must not all be identical (a constant is not jitter).
    new_case
    echo "$(( $(date +%s) + 50 ))" > "$CASE_DIR/exhausted"
    : > "$CASE_DIR/jit"
    i=0
    while [ "$i" -lt 30 ]; do
        rm -f "$CASE_DIR/woke"
        unit 900 >/dev/null 2>&1
        # second sleep line (if any) is the jitter
        sed -n '2p' "$CASE_DIR/unit-sleeps.log" | grep . >> "$CASE_DIR/jit" || echo 0 >> "$CASE_DIR/jit"
        i=$((i+1))
    done
    jmax=$(sort -n "$CASE_DIR/jit" | tail -1); distinct=$(sort -u "$CASE_DIR/jit" | wc -l | tr -d ' ')
    if [ "$jmax" -le 15 ] && [ "$distinct" -ge 3 ]; then pass "7g jitter in 0..15 s and varies (max=$jmax, ${distinct} distinct values)"; else fail "7g jitter" "max=$jmax distinct=$distinct"; fi

    # jitter must never push the total past the caller's bound
    new_case
    echo "$(( $(date +%s) + 50 ))" > "$CASE_DIR/exhausted"
    i=0; worst=0
    while [ "$i" -lt 30 ]; do
        rm -f "$CASE_DIR/woke"
        unit 55 >/dev/null 2>&1
        total=$(awk '{s+=$1} END{print s+0}' "$CASE_DIR/unit-sleeps.log")
        [ "$total" -gt "$worst" ] && worst=$total
        i=$((i+1))
    done
    if [ "$worst" -le 55 ]; then pass "7h wait + jitter clamped to the 55 s bound (worst=$worst)"; else fail "7h clamp" "worst total sleep $worst > 55"; fi
fi

echo
echo "test-gh-graphql-budget: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
