#!/usr/bin/env bash
# Tests for scripts/check-ci.sh (HIMMEL-949).
#
# Hermetic: `gh` is a PATH stub whose behavior is driven by GH_STUB_MODE +
# counter files; CHECK_CI_POLL_INTERVAL=0 removes the grace-window sleeps and
# CHECK_CI_SETTLE=0 disables the settle round unless a case opts in.
# Never talks to GitHub.
#
# Cases:
#   1.  no PR for branch                     → rc 2, stderr echoes gh error
#   2.  "no checks reported" twice, then registered + watch green,
#       0 unresolved threads                 → rc 0
#   3.  checks registered, watch red         → rc 1, FAILED + fast-red hint
#   4.  checks never register, --grace 0     → rc 2, "no checks registered"
#   5.  unknown option                       → rc 2, usage
#   6.  --grace non-numeric                  → rc 2
#   7.  two positional selectors             → rc 2
#   8.  selector is passed through to gh as an exact token
#   9.  settle round catches a late red (green watch 1, red watch 2) → rc 1
#   10. settle round green twice             → rc 0, exactly 2 watch calls
#   11. checks green, 2 unresolved threads   → rc 3
#   12. checks green, thread query fails     → rc 2 (fail-closed gate)
#   13. non-numeric CHECK_CI_POLL_INTERVAL   → warns, falls back, still runs
#   14. --settle non-numeric                 → rc 2
#   15. --threads-only + unresolved threads  → rc 3, and NO gh pr checks calls
#   16. unresolved thread on page TWO        → rc 3 (pagination, codex round 2)
#   17. probe gh error (auth/network)        → rc 2, never a fake red (codex round 3)
#   18. PR head moves during the run         → rc 2 (verdict bound to head SHA)
#   19. CHANGES_REQUESTED review             → rc 3 (codex round 4)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/check-ci.sh"

PASS=0; FAIL=0; COUNT=0; STUBDIR=""

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$STUBDIR" ] && [ -d "$STUBDIR" ]; then rm -rf "$STUBDIR" 2>/dev/null || true; fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

# Fail closed on stub setup: a missing/broken stub would fall through to the
# REAL gh on PATH and turn this "hermetic" suite into live GitHub calls.
STUBDIR=$(mktemp -d) || { echo "FATAL: mktemp -d failed"; exit 1; }
if [ -z "$STUBDIR" ] || [ ! -d "$STUBDIR" ]; then echo "FATAL: no stub dir"; exit 1; fi
cat > "$STUBDIR/gh" <<'EOF'
#!/usr/bin/env bash
# gh stub for test-check-ci.sh — checks behavior via GH_STUB_MODE, probe/watch/
# api counters via GH_STUB_COUNT / GH_STUB_WATCH / GH_STUB_API files,
# unresolved-thread count via GH_STUB_THREADS ("fail" makes the graphql call
# error; "paged" puts the unresolved thread on page two). graphql pages are
# echoed in the script's parsed shape: "<count> <hasNextPage> <endCursor>".
# Args are logged to GH_STUB_ARGS.
echo "$*" >> "$GH_STUB_ARGS"
cmd="${1:-}"
if [ "$cmd" = "api" ]; then
    if [ "${GH_STUB_THREADS:-0}" = "fail" ]; then echo "graphql boom" >&2; exit 1; fi
    if [ "${GH_STUB_THREADS:-0}" = "paged" ]; then
        a=$(cat "$GH_STUB_API" 2>/dev/null)
        a=${a:-0}
        echo $((a+1)) > "$GH_STUB_API"
        if [ "$a" -eq 0 ]; then
            echo "0 true cursor1"
        else
            # page two is only valid when the caller sent page one's cursor
            case " $* " in
                *"cursor1"*) echo "1 false null" ;;
                *) echo "gh stub: page-two request missing cursor1" >&2; exit 99 ;;
            esac
        fi
        exit 0
    fi
    echo "${GH_STUB_THREADS:-0} false null"; exit 0
fi
if [ "$cmd" = "pr" ] && [ "${2:-}" = "view" ]; then
    # a repo with no PR fails pr view too — keep the stub's no-pr mode honest
    if [ "$GH_STUB_MODE" = "no-pr" ]; then
        echo 'no pull requests found for branch "feat/x"' >&2; exit 1
    fi
    case " $* " in
        *"headRefOid"*)
            if [ "${GH_STUB_HEAD:-stable}" = "moving" ]; then
                h=$(cat "$GH_STUB_HEADC" 2>/dev/null)
                h=${h:-0}
                echo $((h+1)) > "$GH_STUB_HEADC"
                echo "sha$((h+1))"
            else
                echo "sha1"
            fi
            exit 0 ;;
        *) echo "https://github.com/octo/demo/pull/42|${GH_STUB_DECISION:-null}"; exit 0 ;;
    esac
fi
# remaining: gh pr checks ...
is_watch=0
case " $* " in *" --watch "*) is_watch=1 ;; esac
case "$GH_STUB_MODE" in
    no-pr)
        echo 'no pull requests found for branch "feat/x"' >&2; exit 1 ;;
    register-then-green)
        n=$(cat "$GH_STUB_COUNT" 2>/dev/null)
        n=${n:-0}
        echo $((n+1)) > "$GH_STUB_COUNT"
        if [ "$n" -lt 2 ]; then
            echo "no checks reported on the 'feat/x' branch" >&2; exit 1
        fi
        if [ "$is_watch" -eq 1 ]; then echo "All checks were successful"; exit 0; fi
        exit 8 ;;
    red)
        if [ "$is_watch" -eq 1 ]; then echo "X ci fail"; exit 1; fi
        exit 8 ;;
    probe-error)
        echo "HTTP 401: Bad credentials (https://api.github.com/graphql)" >&2; exit 1 ;;
    green-then-red)
        if [ "$is_watch" -eq 1 ]; then
            w=$(cat "$GH_STUB_WATCH" 2>/dev/null)
            w=${w:-0}
            echo $((w+1)) > "$GH_STUB_WATCH"
            if [ "$w" -eq 0 ]; then echo "All checks were successful"; exit 0; fi
            echo "X late check failed"; exit 1
        fi
        exit 8 ;;
    never-register)
        echo "no checks reported on the 'feat/x' branch" >&2; exit 1 ;;
    *)
        echo "gh stub: unknown GH_STUB_MODE '$GH_STUB_MODE'" >&2; exit 99 ;;
esac
EOF
chmod +x "$STUBDIR/gh" || { echo "FATAL: chmod on gh stub failed"; exit 1; }
[ -x "$STUBDIR/gh" ] || { echo "FATAL: gh stub not executable"; exit 1; }

OUT=""; ERR=""; RC=0
# Per-case opt-in overrides, reset after every run:
SETTLE_OVERRIDE=0; THREADS_OVERRIDE=0; POLL_OVERRIDE=0; HEAD_OVERRIDE=stable; DECISION_OVERRIDE=null
# run <mode> [args...]
run() {
    local mode="$1"; shift
    COUNT=$((COUNT+1))
    local of ef
    of=$(mktemp); ef=$(mktemp)
    : > "$STUBDIR/args.log"
    : > "$STUBDIR/count"
    : > "$STUBDIR/watch"
    : > "$STUBDIR/api"
    : > "$STUBDIR/headc"
    PATH="$STUBDIR:$PATH" \
        GH_STUB_MODE="$mode" \
        GH_STUB_ARGS="$STUBDIR/args.log" \
        GH_STUB_COUNT="$STUBDIR/count" \
        GH_STUB_WATCH="$STUBDIR/watch" \
        GH_STUB_API="$STUBDIR/api" \
        GH_STUB_HEADC="$STUBDIR/headc" \
        GH_STUB_HEAD="$HEAD_OVERRIDE" \
        GH_STUB_DECISION="$DECISION_OVERRIDE" \
        GH_STUB_THREADS="$THREADS_OVERRIDE" \
        CHECK_CI_POLL_INTERVAL="$POLL_OVERRIDE" \
        CHECK_CI_SETTLE="$SETTLE_OVERRIDE" \
        bash "$SCRIPT" "$@" >"$of" 2>"$ef"
    RC=$?
    OUT=$(cat "$of"); ERR=$(cat "$ef")
    rm -f "$of" "$ef"
    SETTLE_OVERRIDE=0; THREADS_OVERRIDE=0; POLL_OVERRIDE=0; HEAD_OVERRIDE=stable; DECISION_OVERRIDE=null
}

assert_rc()      { if [ "$RC" -eq "$1" ]; then pass "$2"; else fail "$2" "rc=$RC want $1"; fi; }
assert_out_has() { if printf '%s' "$OUT" | grep -iF -- "$1" >/dev/null; then pass "$2"; else fail "$2" "stdout missing: $1"; fi; }
assert_err_has() { if printf '%s' "$ERR" | grep -iF -- "$1" >/dev/null; then pass "$2"; else fail "$2" "stderr missing: $1"; fi; }

echo "test-check-ci.sh"

# 1 — no PR
run no-pr
assert_rc 2 "1 no PR rc 2"
assert_err_has "no pull requests found" "1 no PR gh error surfaced"

# 2 — registers after two probes, watch green, threads resolved
run register-then-green
assert_rc 0 "2 register-then-green rc 0"
assert_out_has "all checks green + all review threads resolved" "2 green verdict on stdout"

# 3 — red (fast) → rc 1 + billing-block hint
run red
assert_rc 1 "3 red rc 1"
assert_err_has "checks FAILED" "3 FAILED on stderr"
assert_err_has "billing" "3 fast-red hint present"

# 4 — never registers, grace 0
run never-register --grace 0
assert_rc 2 "4 never-register rc 2"
assert_err_has "no checks registered within 0s" "4 grace-timeout message"

# 5 — unknown option
run red --bogus
assert_rc 2 "5 unknown option rc 2"
assert_err_has "usage" "5 usage on stderr"

# 6 — non-numeric grace
run red --grace soon
assert_rc 2 "6 non-numeric grace rc 2"
assert_err_has "non-negative integer" "6 grace validation message"

# 7 — two selectors
run red 12 34
assert_rc 2 "7 two selectors rc 2"
assert_err_has "only one PR selector" "7 selector message"

# 8 — selector passed through to gh as an exact token (not a prefix match)
run red 123
assert_rc 1 "8 selector run rc 1"
if grep -Eq '^pr checks 123($|[[:space:]])' "$STUBDIR/args.log"; then
    pass "8 selector forwarded to gh"
else
    fail "8 selector forwarded to gh" "args.log: $(cat "$STUBDIR/args.log")"
fi

# 9 — settle round catches a late red (codex-adv-1 race)
SETTLE_OVERRIDE=1
run green-then-red
assert_rc 1 "9 settle late-red rc 1"
assert_err_has "checks FAILED" "9 late red FAILED on stderr"

# 10 — settle round green twice → rc 0 with exactly two watch calls
SETTLE_OVERRIDE=1
run register-then-green
assert_rc 0 "10 settle green rc 0"
watch_calls=$(grep -c -- '--watch' "$STUBDIR/args.log")
if [ "$watch_calls" -eq 2 ]; then
    pass "10 settle round ran a second watch"
else
    fail "10 settle round ran a second watch" "watch calls=$watch_calls want 2"
fi

# 11 — checks green but unresolved threads → rc 3
THREADS_OVERRIDE=2
run register-then-green
assert_rc 3 "11 unresolved threads rc 3"
assert_err_has "2 unresolved review thread(s)" "11 unresolved-thread message"

# 12 — thread query failure → rc 2 (gate cannot be evaluated, fail-closed)
THREADS_OVERRIDE=fail
run register-then-green
assert_rc 2 "12 thread query failure rc 2"
assert_err_has "review-thread query failed" "12 query-failure message"

# 13 — non-numeric poll interval warns and falls back (red mode: no sleeps hit)
POLL_OVERRIDE=abc
run red
assert_rc 1 "13 non-numeric poll still runs (rc 1 red)"
assert_err_has "CHECK_CI_POLL_INTERVAL" "13 poll fallback warning"

# 14 — non-numeric settle
run red --settle later
assert_rc 2 "14 non-numeric settle rc 2"
assert_err_has "--settle must be a non-negative integer" "14 settle validation message"

# 15 — --threads-only: thread gate runs, checks watch does not
THREADS_OVERRIDE=2
run red --threads-only
assert_rc 3 "15 threads-only unresolved rc 3"
assert_err_has "2 unresolved review thread(s)" "15 threads-only unresolved message"
if grep -- 'checks' "$STUBDIR/args.log" >/dev/null; then
    fail "15 threads-only skips gh pr checks" "args.log: $(cat "$STUBDIR/args.log")"
else
    pass "15 threads-only skips gh pr checks"
fi

# 16 — pagination: page one clean + hasNextPage, unresolved thread on page two
THREADS_OVERRIDE=paged
run register-then-green
assert_rc 3 "16 page-two unresolved rc 3"
assert_err_has "1 unresolved review thread(s)" "16 page-two unresolved counted"

# 17 — probe gh error (auth/network) → rc 2, never a fake red
run probe-error
assert_rc 2 "17 probe error rc 2 (not 1)"
assert_err_has "cannot evaluate the gate" "17 probe-error message"

# 18 — PR head moves between watch and verdict → rc 2 (verdict bound to SHA)
HEAD_OVERRIDE=moving
run register-then-green
assert_rc 2 "18 head moved rc 2"
assert_err_has "PR head moved during the run" "18 head-moved message"
# ordering: capture BEFORE the watch, re-read AFTER — both reads on one side
# of the watch would pass the SHA-change assert while guarding nothing
first_head=$(grep -n 'headRefOid' "$STUBDIR/args.log" | head -1 | cut -d: -f1)
last_head=$(grep -n 'headRefOid' "$STUBDIR/args.log" | tail -1 | cut -d: -f1)
watch_line=$(grep -n -- '--watch' "$STUBDIR/args.log" | head -1 | cut -d: -f1)
if [ -n "$first_head" ] && [ -n "$watch_line" ] && [ -n "$last_head" ] \
    && [ "$first_head" -lt "$watch_line" ] && [ "$watch_line" -lt "$last_head" ]; then
    pass "18 head reads straddle the watch"
else
    fail "18 head reads straddle the watch" "first_head=$first_head watch=$watch_line last_head=$last_head"
fi

# 19 — CHANGES_REQUESTED review → rc 3 (affirmative do-not-merge signal)
DECISION_OVERRIDE=CHANGES_REQUESTED
run register-then-green
assert_rc 3 "19 changes-requested rc 3"
assert_err_has "requests changes" "19 changes-requested message"

echo
echo "ran $COUNT cases; PASS=$PASS FAIL=$FAIL"
if [ "$COUNT" -ne 19 ]; then echo "CASE-COUNT MISMATCH: ran $COUNT want 19"; exit 1; fi
[ "$FAIL" -eq 0 ] || exit 1
