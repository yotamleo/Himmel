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
#   5.  unknown option                       → rc 2, usage, no verdict line
#   5b. --help                               → rc 0, usage, no verdict line
#   (1/2/3/11 additionally assert exactly one exact-match
#   "check-ci: verdict exit=N" line — HIMMEL-974)
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
#   20. gh error mid-watch (auth/network)    → rc 2, never a fake red (CR follow-up)
#   21. malformed hasNextPage (not true/false) → rc 2 (CR follow-up)
#   22. hasNextPage true with empty/null cursor → rc 2 (CR follow-up)
#   23. cursor repeats with hasNextPage=true → rc 2 on query two, no infinite loop (CR follow-up)
#   24. non-adjacent A→B→A cursor cycle      → rc 2 via the 50-page cap (codex follow-up)
#   25. watch exits non-1 with empty stderr  → rc 2, only gh rc 1 is a red check (CR follow-up)
#   26. watch rc 1 but zero checks in the fail bucket → rc 2 (structured red confirm, codex)
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
    case "${2:-}" in
        repos/octo/demo/commits/sha1/check-runs*)
            case "$GH_STUB_MODE" in
                zombie|zombie-no-status|zombie-status-error|zombie-late)
                    echo '{"check_runs":[{"name":"CodeRabbit","status":"in_progress","started_at":"2000-01-01T00:00:00Z"}]}' ;;
                zombie-young)
                    echo "{\"check_runs\":[{\"name\":\"CodeRabbit\",\"status\":\"in_progress\",\"started_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]}" ;;
                *) echo '{"check_runs":[]}' ;;
            esac
            exit 0 ;;
        repos/octo/demo/commits/sha1/status)
            case "$GH_STUB_MODE" in
                zombie|zombie-late) echo '{"statuses":[{"context":"CodeRabbit","state":"success"}]}' ;;
                zombie-status-error) echo "status boom" >&2; exit 1 ;;
                zombie-no-status) echo '{"statuses":[]}' ;;
                *) echo '{"statuses":[{"context":"CodeRabbit","state":"pending"}]}' ;;
            esac
            exit 0 ;;
    esac
    if [ "${GH_STUB_THREADS:-0}" = "fail" ]; then echo "graphql boom" >&2; exit 1; fi
    if [ "${GH_STUB_THREADS:-0}" = "badnext" ]; then echo "0 banana cursor1"; exit 0; fi
    if [ "${GH_STUB_THREADS:-0}" = "nullcursor" ]; then echo "0 true null"; exit 0; fi
    if [ "${GH_STUB_THREADS:-0}" = "repeatcursor" ]; then echo "0 true cursor1"; exit 0; fi
    if [ "${GH_STUB_THREADS:-0}" = "cyclecursor" ]; then
        a=$(cat "$GH_STUB_API" 2>/dev/null)
        a=${a:-0}
        echo $((a+1)) > "$GH_STUB_API"
        # alternate cursorA / cursorB forever: A→B→A cycle, hasNextPage always true
        if [ $((a % 2)) -eq 0 ]; then echo "0 true cursorA"; else echo "0 true cursorB"; fi
        exit 0
    fi
    if [ "${GH_STUB_THREADS:-0}" = "latethread" ]; then
        # First thread query (pre-watch gate) is clean; every later query
        # (the post-watch re-verification) reports one unresolved thread —
        # a review comment that landed DURING the watch (codex-adv 980-r2).
        a=$(cat "$GH_STUB_API" 2>/dev/null)
        a=${a:-0}
        echo $((a+1)) > "$GH_STUB_API"
        if [ "$a" -eq 0 ]; then echo "0 false null"; else echo "1 false null"; fi
        exit 0
    fi
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
# structured red confirm (--json bucket): the script's --jq yields a bare count
case " $* " in
    *" --json "*)
        case "$GH_STUB_MODE" in
            zombie-late)
                # First checks --json probe (zombie other_pending snapshot)
                # sees 0; the settle re-probe (and later calls) see 1 late
                # arrival. Count only `pr checks … --json` lines — pr_view's
                # `--json headRefOid` calls land in the same args log.
                njson=$(grep -c "^pr checks .*--json" "$GH_STUB_ARGS" 2>/dev/null); njson=${njson:-1}
                if [ "$njson" -le 1 ]; then echo 0; else echo 1; fi ;;
            red-liar|zombie|zombie-young|zombie-no-status|zombie-status-error) echo 0 ;;
            *) echo 1 ;;
        esac
        exit 0 ;;
esac
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
    watch-pending)
        if [ "$is_watch" -eq 1 ]; then exit 8; fi
        exit 8 ;;
    red-liar)
        # rc 1 with EMPTY stdout+stderr — gh's generic failure masquerading as red
        if [ "$is_watch" -eq 1 ]; then exit 1; fi
        exit 8 ;;
    watch-error)
        if [ "$is_watch" -eq 1 ]; then echo "HTTP 401: Bad credentials (https://api.github.com/graphql)" >&2; exit 1; fi
        exit 8 ;;
    zombie|zombie-young|zombie-no-status|zombie-status-error)
        if [ "$is_watch" -eq 1 ]; then echo "gh stub: zombie watch must not complete" >&2; exit 99; fi
        exit 8 ;;
    zombie-late)
        # After the dropped override the watch path MUST run — and completes green.
        if [ "$is_watch" -eq 1 ]; then echo "All checks were successful"; exit 0; fi
        exit 8 ;;
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
# Exactly ONE verdict line, exact-match to the expected code (HIMMEL-974) —
# a substring check would pass on a double-fired trap or a wrong-code line.
assert_verdict() {
    local n
    n=$(printf '%s\n' "$OUT" | grep -c -x "check-ci: verdict exit=$1")
    local total
    total=$(printf '%s\n' "$OUT" | grep -c "check-ci: verdict exit=")
    if [ "$n" -eq 1 ] && [ "$total" -eq 1 ]; then
        pass "$2"
    else
        fail "$2" "want exactly 1 'verdict exit=$1' line, got $n (total verdict lines: $total)"
    fi
}
assert_no_verdict() {
    if printf '%s' "$OUT$ERR" | grep -F "verdict exit=" >/dev/null; then
        fail "$1" "verdict line leaked into a pre-trap exit"
    else
        pass "$1"
    fi
}

echo "test-check-ci.sh"

# 1 — no PR
run no-pr
assert_rc 2 "1 no PR rc 2"
assert_err_has "no pull requests found" "1 no PR gh error surfaced"
assert_verdict 2 "1 un-maskable verdict line (HIMMEL-974)"

# 2 — registers after two probes, watch green, threads resolved
run register-then-green
assert_rc 0 "2 register-then-green rc 0"
assert_out_has "all checks green + all review threads resolved" "2 green verdict on stdout"
assert_verdict 0 "2 un-maskable verdict line (HIMMEL-974)"

# 3 — red (fast) → rc 1 + billing-block hint
run red
assert_rc 1 "3 red rc 1"
assert_err_has "checks FAILED" "3 FAILED on stderr"
assert_err_has "billing" "3 fast-red hint present"
assert_verdict 1 "3 un-maskable verdict line (HIMMEL-974)"

# 4 — never registers, grace 0
run never-register --grace 0
assert_rc 2 "4 never-register rc 2"
assert_err_has "no checks registered within 0s" "4 grace-timeout message"

# 5 — unknown option (pre-trap usage error: NO verdict line)
run red --bogus
assert_rc 2 "5 unknown option rc 2"
assert_err_has "usage" "5 usage on stderr"
assert_no_verdict "5 no verdict line on usage errors"

# 5b — --help exits 0 pre-trap: usage only, NO verdict line
run red --help
assert_rc 0 "5b --help rc 0"
assert_err_has "usage" "5b usage on stderr"
assert_no_verdict "5b no verdict line on --help"

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
assert_verdict 3 "11 un-maskable verdict line (HIMMEL-974)"

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

# 20 — gh error mid-watch (auth/network) → rc 2, never a fake red
run watch-error
assert_rc 2 "20 watch-error rc 2"
assert_err_has "cannot evaluate the gate" "20 watch-error message"

# 21 — malformed hasNextPage (neither true nor false) → rc 2, after exactly ONE query
THREADS_OVERRIDE=badnext
run register-then-green
assert_rc 2 "21 malformed hasNextPage rc 2"
assert_err_has "malformed page" "21 malformed hasNextPage message"
api_calls=$(grep -c '^api graphql' "$STUBDIR/args.log")
if [ "$api_calls" -eq 1 ]; then pass "21 exactly one thread query"; else fail "21 exactly one thread query" "api calls=$api_calls want 1"; fi

# 22 — hasNextPage true with an empty/null cursor → rc 2 (must not loop or stop early)
THREADS_OVERRIDE=nullcursor
run register-then-green
assert_rc 2 "22 hasNextPage true empty cursor rc 2"
assert_err_has "malformed page" "22 hasNextPage true empty cursor message"
api_calls=$(grep -c '^api graphql' "$STUBDIR/args.log")
if [ "$api_calls" -eq 1 ]; then pass "22 exactly one thread query"; else fail "22 exactly one thread query" "api calls=$api_calls want 1"; fi

# 23 — cursor repeats with hasNextPage=true → rc 2 after the SECOND query (no infinite loop)
THREADS_OVERRIDE=repeatcursor
run register-then-green
assert_rc 2 "23 repeated cursor rc 2"
assert_err_has "cursor did not advance" "23 repeated-cursor message"
api_calls=$(grep -c '^api graphql' "$STUBDIR/args.log")
if [ "$api_calls" -eq 2 ]; then pass "23 exactly two thread queries"; else fail "23 exactly two thread queries" "api calls=$api_calls want 2"; fi

# 24 — non-adjacent cursor cycle (A→B→A, hasNextPage always true) → the page cap
#      fails closed at 50 queries instead of looping forever
THREADS_OVERRIDE=cyclecursor
run register-then-green
assert_rc 2 "24 cursor cycle rc 2"
assert_err_has "did not terminate within 50 pages" "24 page-cap message"
api_calls=$(grep -c '^api graphql' "$STUBDIR/args.log")
if [ "$api_calls" -eq 50 ]; then pass "24 capped at 50 thread queries"; else fail "24 capped at 50 thread queries" "api calls=$api_calls want 50"; fi

# 25 — watch exits non-1 with EMPTY stderr (e.g. rc 8 pending after an
#      interrupted watch) → cannot evaluate, never a fake red
run watch-pending
assert_rc 2 "25 watch rc!=1 empty stderr rc 2"
assert_err_has "with no error output" "25 non-red watch message"

# 26 — watch exits rc 1 silently but NO check is in the fail bucket (gh's
#      generic failure code masquerading as red) → cannot evaluate
run red-liar
assert_rc 2 "26 red-liar rc 2"
assert_err_has "no check is in the fail bucket" "26 structured-confirm message"

# 27 — old in-progress CodeRabbit + successful same-head commit status + clean
# threads overrides the zombie and never enters the hanging watch.
run zombie
assert_rc 0 "27 zombie override rc 0"
assert_out_has "zombie check-run override:" "27 zombie override loud line"
assert_out_has "commit status=success + 0 unresolved threads" "27 zombie evidence printed"

# 28 — a young in-progress run remains blocking (the watch path cannot certify).
run zombie-young
assert_rc 2 "28 young in-progress still blocks"

# 29 — old run without successful commit status remains blocking.
run zombie-no-status
assert_rc 2 "29 old run without success still blocks"

# 30 — unresolved threads prevent override before the status probe.
THREADS_OVERRIDE=1
run zombie
assert_rc 3 "30 old success with unresolved thread blocks"

# 31 — status API errors are no-override and remain fail-closed.
run zombie-status-error
assert_rc 2 "31 status probe error still blocks"

# 32 — a non-CodeRabbit check registering during the settle window drops the
# override: the run falls back to the watch path (which completes green here)
# instead of certifying on the stale snapshot (codex-adv-2).
SETTLE_OVERRIDE=1
run zombie-late
assert_rc 0 "32 late-check settle re-probe rc 0 via watch path"
assert_out_has "zombie check-run override:" "32 override initially taken"
assert_out_has "zombie override dropped:" "32 override dropped on late arrival"
grep -q -- "--watch" "$STUBDIR/args.log" || { echo "FAIL: 32 watch path never ran"; FAIL=$((FAIL+1)); }

# 33 — an unresolved thread landing DURING the watch (head SHA unmoved) is
# caught by the post-watch review-state re-verification, not certified from
# the stale pre-watch snapshot (codex-adv 980-r2).
THREADS_OVERRIDE=latethread
run register-then-green
assert_rc 3 "33 late thread post-watch blocks"
assert_err_has "unresolved review thread" "33 late-thread reason printed"

echo
echo "ran $COUNT cases; PASS=$PASS FAIL=$FAIL"
if [ "$COUNT" -ne 34 ]; then echo "CASE-COUNT MISMATCH: ran $COUNT want 34"; exit 1; fi
[ "$FAIL" -eq 0 ] || exit 1
