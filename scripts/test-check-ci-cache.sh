#!/usr/bin/env bash
# Tests for the shared per-PR CI status cache, the adaptive watch helper and the
# API-budget wait (HIMMEL-3850 — the fleet exhausted the shared GitHub quota by
# every waiting leg polling `gh pr checks --watch` on its own).
#
#   scripts/lib/gh-ci-cache.sh   cic_init / cic_get: one file per PR, head-tagged,
#                                mkdir-locked, TTL; budget wait through `gh api rate_limit`
#   scripts/lib/check-ci-watch.sh the bounded watch replacement: adaptive interval
#                                over cached snapshots, gh's own verdict contract
#   scripts/ci/api-budget.sh     the read-only `gh-api: remaining=R/5000 reset=HH:MMZ` line
#   scripts/check-ci.sh          wired to all of the above when CHECK_CI_CACHE=1 (default)
#
# Hermetic: `gh` is a PATH stub that records every call. The CLOCK is fake: the
# lib and helper read CIC_CLOCK_FILE, and the sleep seam is an exported function
# that advances that file, so TTL expiry and a 120 s backoff cost milliseconds.
#
# Cases:
#   1.  N concurrent waiters on one PR -> exactly ONE fetch; all read the same rows
#   2.  TTL: hit inside it, refetch past it; a tighter "decide" TTL refetches sooner
#   3.  a push (head changes) invalidates the entry; a head that moves DURING the
#       fetch is never cached (no stale-head green)
#   4.  remaining below the floor (core OR graphql) -> waits for the reset, one line, then fetches
#   5.  a 403 rate limit on the fetch -> waits for the reset, resumes; never cached
#   6.  reset beyond the caller's --max-wait bound -> not waiting, rc 2
#   7.  helper: an unchanged rollup backs the interval off to the ceiling; a change resets it
#   8.  helper verdicts (green / red / cancel / error / no rows) keep gh's contract
#   9.  api-budget.sh prints the one-line budget
#   10. check-ci end to end: green / red / cap-with-pending decisions unchanged, and N
#       concurrent check-ci runs on one PR fetch the rollup far fewer times than N runs
#   11. CHECK_CI_CACHE=0 keeps the legacy `gh pr checks --watch` path
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/gh-ci-cache.sh"
HELPER="$SCRIPT_DIR/lib/check-ci-watch.sh"
BUDGET="$SCRIPT_DIR/ci/api-budget.sh"
CHECK_CI="$SCRIPT_DIR/check-ci.sh"
# shellcheck source=scripts/lib/timeout-bin.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/timeout-bin.sh"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/check-ci-cache.XXXXXX") || { echo "FATAL: mktemp -d failed"; exit 1; }
[ -d "$ROOT" ] || { echo "FATAL: no temp dir"; exit 1; }
# shellcheck disable=SC2329,SC2317
cleanup() { if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then rm -rf "$ROOT" 2>/dev/null; fi; return 0; }
trap cleanup EXIT

BIN="$ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
# gh stub for test-check-ci-cache.sh. State dir: $GHC_DIR.
#   clock       fake epoch seconds (the sleep seam advances it)
#   head        the PR head sha `gh pr view --json headRefOid` prints (default sha1)
#   rows        "<bucket>\t<name>" lines `gh pr checks --json bucket,name` prints;
#               rows.<n> overrides it for the n-th fetch (n counts from 1)
#   rl_reset    fake epoch of the rate-limit reset (default clock+3000, i.e. healthy)
#   rl_core / rl_gql   remaining while clock < rl_reset (default 5000)
#   mode        rl-once   first fetch fails "API rate limit exceeded" and drops the budget for 60 s
#               headflip  the head moves the instant a fetch has been served
#               err       fetch fails with a non-rate-limit error
#               slow      fetch takes 0.4 s (widens a race)
#   calls.log   every gh call, one line
D="$GHC_DIR"
echo "$*" >> "$D/calls.log"
clock=$(cat "$D/clock" 2>/dev/null); clock=${clock:-1000000000}
mode=$(cat "$D/mode" 2>/dev/null)
cmd="${1:-}"
rl_state() {
    local reset; reset=$(cat "$D/rl_reset" 2>/dev/null); reset=${reset:-$((clock + 3000))}
    if [ "$clock" -lt "$reset" ]; then
        core=$(cat "$D/rl_core" 2>/dev/null); core=${core:-5000}
        gql=$(cat "$D/rl_gql" 2>/dev/null); gql=${gql:-5000}
    else core=5000; gql=5000; fi
    RESET=$reset
}
if [ "$cmd" = "api" ]; then
    case " $* " in
        *" rate_limit "*)
            rl_state
            # post --jq shape the lib asks for: "<core rem> <core reset> <gql rem> <gql reset>"
            case " $* " in *core.limit*) echo "$core $RESET $gql 5000 5000" ;; *) echo "$core $RESET $gql $RESET" ;; esac
            exit 0 ;;
        *" -i "*)
            rl_state
            printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: %s\r\nX-Ratelimit-Reset: %s\r\n\r\n{"data":{}}\n' "$gql" "$RESET"; exit 0 ;;
        *graphql*) echo "0 false null"; exit 0 ;;
        *rules/branches*|*protection/required_status_checks*) exit 0 ;;
        *) echo '[]'; exit 0 ;;
    esac
fi
if [ "$cmd" = "pr" ] && [ "${2:-}" = "view" ]; then
    case " $* " in
        *mergeStateStatus*) echo "$(cat "$D/head" 2>/dev/null || echo sha1) CLEAN" ;;
        *headRefOid*)  cat "$D/head" 2>/dev/null || echo sha1 ;;
        *baseRefName*) echo main ;;
        *author,files*) printf 'MPR_OK\noctocat\nfalse\n1\nREADME.md\n' ;;
        *)             echo "https://github.com/octo/demo/pull/42|null" ;;
    esac
    exit 0
fi
# gh pr checks ...
case " $* " in
    *" --watch "*)
        echo "All checks were successful"; exit 0 ;;
    *" --json bucket,name "*)
        n=$(grep -c -- '--json bucket,name' "$D/calls.log")
        [ "$mode" = slow ] && sleep 0.4
        if [ "$mode" = rl-once ] && [ ! -f "$D/rlfired" ]; then
            touch "$D/rlfired"; echo "$((clock + 60))" > "$D/rl_reset"; echo 0 > "$D/rl_core"
            echo "HTTP 403: API rate limit exceeded for user ID 1." >&2; exit 1
        fi
        if [ "$mode" = err ]; then echo "error connecting to api.github.com" >&2; exit 1; fi
        if [ -f "$D/rows.$n" ]; then cat "$D/rows.$n"; else cat "$D/rows" 2>/dev/null; fi
        [ "$mode" = headflip ] && echo sha2 > "$D/head"
        exit 0 ;;
    *" --json bucket "*)
        awk -F'\t' '$1=="fail"{c++} END{print c+0}' "$D/rows" 2>/dev/null; exit 0 ;;
    *)  exit 8 ;;
esac
EOF
chmod +x "$BIN/gh" || { echo "FATAL: chmod gh stub"; exit 1; }

# The fake clock + the sleep seam every wait goes through.
fakesleep() {
    local now; now=$(cat "$GHC_DIR/clock" 2>/dev/null); now=${now:-1000000000}
    echo $((now + ${1:-0})) > "$GHC_DIR/clock"
    SECONDS=$((SECONDS + ${1:-0}))
    echo "${1:-0}" >> "$GHC_DIR/sleeps.log"
    return 0
}
export -f fakesleep

new_case() {
    CASE_DIR=$(mktemp -d "$ROOT/case.XXXXXX") || { echo "FATAL: mktemp case"; exit 1; }
    : > "$CASE_DIR/calls.log"; : > "$CASE_DIR/sleeps.log"
    echo 1000000000 > "$CASE_DIR/clock"
    printf 'pending\tunit-tests\npass\tlint\n' > "$CASE_DIR/rows"
    mkdir -p "$CASE_DIR/cwd" "$CASE_DIR/cache"
    export GHC_DIR="$CASE_DIR"
    export CHECK_CI_CACHE_DIR="$CASE_DIR/cache"
    export CIC_CLOCK_FILE="$CASE_DIR/clock"
    export CIC_SLEEP_CMD=fakesleep
    export CHECK_CI_WATCH_SLEEP_CMD=fakesleep
    export GH_BUDGET_JITTER_MAX=0
    export PATH="$BIN:$ORIG_PATH"
}
ORIG_PATH="$PATH"
fetches() { grep -c -- '--json bucket,name' "$CASE_DIR/calls.log"; }
sleeps() { tr '\n' ' ' < "$CASE_DIR/sleeps.log"; }
setclock() { echo "$1" > "$CASE_DIR/clock"; }

echo "test-check-ci-cache.sh"

if [ ! -f "$LIB" ]; then
    fail "0 lib exists" "$LIB is missing (RED: nothing implemented yet)"
else
# shellcheck source=scripts/lib/gh-ci-cache.sh
# shellcheck disable=SC1091
. "$LIB"

# 1 — N concurrent waiters, one PR, one fetch.
new_case
echo slow > "$CASE_DIR/mode"
for i in 1 2 3 4 5 6 7 8; do
    ( cic_init "" && cic_get 60 && printf '%s\n' "$CIC_ROWS" > "$CASE_DIR/out.$i" ) &
done
wait
n=$(fetches)
if [ "$n" -eq 1 ]; then pass "1 8 concurrent waiters -> 1 fetch"; else fail "1 fetch count" "got $n fetches, want 1"; fi
same=$(cat "$CASE_DIR"/out.* | sort -u | wc -l | tr -d ' ')
if [ "$(find "$CASE_DIR" -maxdepth 1 -name 'out.*' | wc -l | tr -d ' ')" -eq 8 ] && [ "$same" -eq 2 ]; then pass "1b every waiter read the same 2 rows"; else fail "1b rows" "distinct lines=$same"; fi
: > "$CASE_DIR/calls.log"; echo > "$CASE_DIR/mode"

# 2 — TTL and the tighter decide TTL.
new_case
cic_init "" && cic_get 60; cic_init "" && cic_get 60
n=$(fetches); if [ "$n" -eq 1 ]; then pass "2 second read inside the TTL is a hit"; else fail "2 hit" "fetches=$n want 1"; fi
setclock 1000000030
cic_init "" && cic_get 60; n=$(fetches); if [ "$n" -eq 1 ]; then pass "2b age 30 < TTL 60: still a hit"; else fail "2b" "fetches=$n want 1"; fi
cic_init "" && cic_get 5; n=$(fetches); if [ "$n" -eq 2 ]; then pass "2c age 30 > decide TTL 5: refetch"; else fail "2c" "fetches=$n want 2"; fi
setclock 1000000100
cic_init "" && cic_get 60; n=$(fetches); if [ "$n" -eq 3 ]; then pass "2d past the TTL: refetch"; else fail "2d" "fetches=$n want 3"; fi

# 3 — the head binds the entry.
new_case
cic_init "" && cic_get 60
echo sha9 > "$CASE_DIR/head"
cic_init "" && cic_get 60
n=$(fetches); if [ "$n" -eq 2 ]; then pass "3 a new head misses the old head's entry"; else fail "3 head miss" "fetches=$n want 2"; fi
new_case
echo headflip > "$CASE_DIR/mode"
cic_init "" && cic_get 60
echo sha2 > "$CASE_DIR/head"; echo > "$CASE_DIR/mode"
cic_init "" && cic_get 60
n=$(fetches); if [ "$n" -eq 2 ]; then pass "3b a head that moved during the fetch is not cached"; else fail "3b bracket" "fetches=$n want 2 (a stale-head entry was served)"; fi

# 4 — remaining below the floor waits (core, then graphql).
new_case
echo 1000000090 > "$CASE_DIR/rl_reset"; echo 100 > "$CASE_DIR/rl_core"
cic_init "" ; cic_get 60 2>"$CASE_DIR/err"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sort -n "$CASE_DIR/sleeps.log" | tail -1)" -ge 90 ] 2>/dev/null; then pass "4 core remaining 100 < floor 300: slept to the reset (sleeps: $(sleeps))"; else fail "4 core wait" "rc=$rc sleeps=$(sleeps)"; fi
if [ "$(grep -c 'budget low' "$CASE_DIR/err")" -le 1 ]; then pass "4b at most one budget line"; else fail "4b line count" "$(cat "$CASE_DIR/err")"; fi
new_case
echo 1000000090 > "$CASE_DIR/rl_reset"; echo 100 > "$CASE_DIR/rl_gql"
cic_init "" ; cic_get 60 2>"$CASE_DIR/err"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sort -n "$CASE_DIR/sleeps.log" | tail -1)" -ge 90 ] 2>/dev/null; then pass "4c graphql remaining 100 < floor: slept to the reset"; else fail "4c graphql wait" "rc=$rc sleeps=$(sleeps)"; fi
if grep -q 'budget low' "$CASE_DIR/err"; then pass "4d prints one line saying so"; else fail "4d message" "stderr: $(cat "$CASE_DIR/err")"; fi
new_case
echo 300 > "$CASE_DIR/rl_core"
cic_init "" ; cic_get 60 2>/dev/null
if [ ! -s "$CASE_DIR/sleeps.log" ]; then pass "4e remaining == floor: no wait"; else fail "4e floor edge" "sleeps=$(sleeps)"; fi
new_case
echo 100 > "$CASE_DIR/rl_core"
CHECK_CI_API_FLOOR=0 cic_init "" ; CHECK_CI_API_FLOOR=0 cic_get 60 2>/dev/null
if [ ! -s "$CASE_DIR/sleeps.log" ] && ! grep -q rate_limit "$CASE_DIR/calls.log"; then pass "4f CHECK_CI_API_FLOOR=0 opts out (no wait, no rate_limit call)"; else fail "4f opt-out" "sleeps=$(sleeps)"; fi

# 5 — a 403 on the fetch: wait for the reset, resume, never cache the error.
new_case
echo rl-once > "$CASE_DIR/mode"
cic_init "" ; cic_get 60 2>"$CASE_DIR/err"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sort -n "$CASE_DIR/sleeps.log" | tail -1)" -ge 60 ] 2>/dev/null; then pass "5 403 -> waited for the reset, then resumed rc 0 (sleeps: $(sleeps))"; else fail "5 403" "rc=$rc sleeps=$(sleeps) err=$(cat "$CASE_DIR/err")"; fi
if [ -n "$CIC_ROWS" ]; then pass "5b rows arrived after the resume"; else fail "5b rows" "CIC_ROWS empty"; fi
# a plain error is returned (rc 1), cached briefly, and is not a wait
new_case
echo err > "$CASE_DIR/mode"
cic_init "" ; cic_get 60 2>/dev/null; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$CIC_ERR" | grep -q 'error connecting'; then pass "5c non-rate-limit error: rc 1, text kept"; else fail "5c error" "rc=$rc err=$CIC_ERR"; fi
cic_init "" ; cic_get 60 2>/dev/null; n=$(fetches)
if [ "$n" -eq 1 ]; then pass "5d the error is cached for the short error TTL (no hammering)"; else fail "5d err ttl" "fetches=$n want 1"; fi
setclock 1000000020
cic_init "" ; cic_get 60 2>/dev/null; n=$(fetches)
if [ "$n" -eq 2 ]; then pass "5e past the error TTL: retried"; else fail "5e" "fetches=$n want 2"; fi

# 6 — reset beyond the bound.
new_case
echo 1000001000 > "$CASE_DIR/rl_reset"; echo 0 > "$CASE_DIR/rl_core"
CIC_MAX_WAIT=60 cic_init "" ; CIC_MAX_WAIT=60 cic_get 60 2>"$CASE_DIR/err"; rc=$?
if [ "$rc" -eq 2 ]; then pass "6 reset beyond --max-wait: rc 2"; else fail "6 rc" "rc=$rc"; fi
if [ ! -s "$CASE_DIR/sleeps.log" ] && [ "$(fetches)" -eq 0 ]; then pass "6b no sleep, no fetch"; else fail "6b" "sleeps=$(sleeps) fetches=$(fetches)"; fi
fi

# 7 — helper: adaptive interval.
if [ ! -f "$HELPER" ]; then
    fail "7 helper exists" "$HELPER is missing"
else
    new_case
    printf 'pending\tunit-tests\n' > "$CASE_DIR/rows"
    # Polls land at t=0,30,90,210,... (a poll inside the 60 s TTL is a cache hit,
    # not a fetch), so fetch n is poll n+1 from the third poll on: the rollup
    # CHANGES on fetch 6 (poll 7) and settles on fetch 8 (poll 9).
    printf 'pending\tunit-tests\npending\tlint\n' > "$CASE_DIR/rows.6"
    cp "$CASE_DIR/rows.6" "$CASE_DIR/rows.7"
    printf 'pass\tunit-tests\n' > "$CASE_DIR/rows.8"
    timeout_run() { if [ -n "${_TIMEOUT_BIN:-}" ]; then "$_TIMEOUT_BIN" -k 5 60 "$@"; else "$@"; fi; }
    CHECK_CI_CACHE_TTL=60 timeout_run bash "$HELPER" > "$CASE_DIR/out" 2> "$CASE_DIR/err"; rc=$?
    seq=$(sleeps)
    if [ "$rc" -eq 0 ]; then pass "7 helper ends green rc 0 once the rollup settles"; else fail "7 rc" "rc=$rc err=$(cat "$CASE_DIR/err")"; fi
    case "$seq" in "30 60 120 120 120 120 30 60 120 ") pass "7b interval doubles to the 120 s ceiling on an unchanged rollup, resets to 30 on a change ($seq)" ;; *) fail "7b interval" "sleeps: $seq" ;; esac
    if grep -q 'All checks were successful' "$CASE_DIR/out"; then pass "7c prints gh's green line"; else fail "7c line" "$(cat "$CASE_DIR/out")"; fi
    new_case
    printf 'pending\tunit-tests\n' > "$CASE_DIR/rows"; printf 'pass\tunit-tests\n' > "$CASE_DIR/rows.4"
    CHECK_CI_CACHE_TTL=1 CHECK_CI_WATCH_INTERVAL=10 CHECK_CI_WATCH_INTERVAL_MAX=25 timeout_run bash "$HELPER" >/dev/null 2>&1
    case "$(sleeps)" in "10 20 25 ") pass "7d floor/ceiling knobs are honoured" ;; *) fail "7d knobs" "sleeps: $(sleeps)" ;; esac

    # 8 — verdicts.
    new_case
    printf 'pass\ta\nskipping\tb\n' > "$CASE_DIR/rows"
    timeout_run bash "$HELPER" > "$CASE_DIR/out" 2>"$CASE_DIR/err"; rc=$?
    if [ "$rc" -eq 0 ] && [ ! -s "$CASE_DIR/sleeps.log" ]; then pass "8 all pass/skipping -> rc 0, no wait"; else fail "8 green" "rc=$rc sleeps=$(sleeps)"; fi
    new_case
    printf 'pass\ta\nfail\tunit-tests\npending\tz\n' > "$CASE_DIR/rows"
    timeout_run bash "$HELPER" > "$CASE_DIR/out" 2>"$CASE_DIR/err"; rc=$?
    if [ "$rc" -eq 1 ] && grep -q 'X.*unit-tests' "$CASE_DIR/out" && [ ! -s "$CASE_DIR/err" ]; then pass "8b a fail (others still pending) -> rc 1, failure on stdout, empty stderr (--fail-fast)"; else fail "8b red" "rc=$rc out=$(cat "$CASE_DIR/out") err=$(cat "$CASE_DIR/err")"; fi
    new_case
    printf 'cancel\tunit-tests\n' > "$CASE_DIR/rows"
    timeout_run bash "$HELPER" > "$CASE_DIR/out" 2>"$CASE_DIR/err"; rc=$?
    if [ "$rc" -eq 1 ]; then pass "8c a cancelled check is never green (rc 1)"; else fail "8c cancel" "rc=$rc"; fi
    new_case
    echo err > "$CASE_DIR/mode"
    timeout_run bash "$HELPER" > "$CASE_DIR/out" 2>"$CASE_DIR/err"; rc=$?
    if [ "$rc" -eq 1 ] && grep -q 'error connecting' "$CASE_DIR/err"; then pass "8d fetch error -> rc 1 with the error on stderr (check-ci maps it to exit 2)"; else fail "8d error" "rc=$rc err=$(cat "$CASE_DIR/err")"; fi
    new_case
    : > "$CASE_DIR/rows"
    timeout_run bash "$HELPER" > "$CASE_DIR/out" 2>"$CASE_DIR/err"; rc=$?
    if [ "$rc" -eq 1 ] && [ -s "$CASE_DIR/err" ]; then pass "8e no rows is an error, never green (fail closed)"; else fail "8e empty" "rc=$rc out=$(cat "$CASE_DIR/out")"; fi
    new_case
    printf 'pass\ta\n' > "$CASE_DIR/rows"
    echo headflip > "$CASE_DIR/mode"
    timeout_run bash "$HELPER" >/dev/null 2>&1
    n=$(fetches)
    if [ "$n" -ge 2 ]; then pass "8f a green is confirmed with a fresh read (decide TTL), not the poll snapshot alone"; else fail "8f confirm" "fetches=$n want >= 2"; fi
fi

# 9 — api-budget.sh
if [ ! -f "$BUDGET" ]; then
    fail "9 api-budget.sh exists" "$BUDGET is missing"
else
    new_case
    echo 1000000090 > "$CASE_DIR/rl_reset"; echo 4321 > "$CASE_DIR/rl_core"
    out=$(bash "$BUDGET" 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Eq '^gh-api: remaining=4321/5000 reset=[0-9]{2}:[0-9]{2}Z'; then pass "9 prints gh-api: remaining=R/5000 reset=HH:MMZ ($out)"; else fail "9 line" "rc=$rc out=$out"; fi
    if [ "$(grep -vc 'rate_limit' "$CASE_DIR/calls.log")" -eq 0 ]; then pass "9b read-only: only the free rate_limit endpoint is called"; else fail "9b calls" "$(cat "$CASE_DIR/calls.log")"; fi
fi

# 10 — check-ci end to end (cache on).
run_ci() {   # run_ci <outfile-prefix> <check-ci args...>
    local p="$1"; shift
    ( cd "$CASE_DIR/cwd" && \
      CHECK_CI_SLEEP_CMD="${RUN_SLEEP:-fakesleep}" CHECK_CI_SETTLE=0 CR_APP=0 CR_PROFILE=none GH_BUDGET_PREFLIGHT=0 \
      CHECK_CI_WATCH_INTERVAL=1 \
      ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 120} bash "$CHECK_CI" "$@" >"$p.out" 2>"$p.err" )
    echo $? > "$p.rc"
}
if [ ! -f "$HELPER" ]; then
    fail "10 check-ci cache wiring" "helper missing"
else
    new_case
    printf 'pass\tunit-tests\n' > "$CASE_DIR/rows"
    run_ci "$CASE_DIR/g" 42 --max-wait 900
    if [ "$(cat "$CASE_DIR/g.rc")" -eq 0 ]; then pass "10 green -> rc 0 through the cache"; else fail "10 green" "rc=$(cat "$CASE_DIR/g.rc") err=$(cat "$CASE_DIR/g.err")"; fi
    if ! grep -q -- '--watch' "$CASE_DIR/calls.log"; then pass "10b no gh --watch was started (the cached helper replaced it)"; else fail "10b watch" "a --watch call was made"; fi
    new_case
    printf 'fail\tunit-tests\npending\tz\n' > "$CASE_DIR/rows"
    run_ci "$CASE_DIR/r" 42 --max-wait 900
    if [ "$(cat "$CASE_DIR/r.rc")" -eq 1 ]; then pass "10c red -> rc 1 through the cache"; else fail "10c red" "rc=$(cat "$CASE_DIR/r.rc") err=$(cat "$CASE_DIR/r.err")"; fi
    new_case
    printf 'pending\tunit-tests\n' > "$CASE_DIR/rows"
    run_ci "$CASE_DIR/p" 42 --max-wait 60
    if [ "$(cat "$CASE_DIR/p.rc")" -eq 2 ]; then pass "10d never-settling checks hit the cap -> rc 2 unchanged"; else fail "10d cap" "rc=$(cat "$CASE_DIR/p.rc") err=$(cat "$CASE_DIR/p.err")"; fi
    new_case
    printf 'pending\tCodeRabbit\npass\tunit-tests\n' > "$CASE_DIR/rows"
    run_ci "$CASE_DIR/c" 42 --max-wait 900
    if [ "$(cat "$CASE_DIR/c.rc")" -eq 0 ]; then pass "10e only CodeRabbit pending -> decidable, rc 0 unchanged"; else fail "10e decidable" "rc=$(cat "$CASE_DIR/c.rc") err=$(cat "$CASE_DIR/c.err")"; fi

    # A second run inside the TTL reads the first run's snapshot.
    new_case
    printf 'pass\tunit-tests\n' > "$CASE_DIR/rows"
    RUN_SLEEP=: run_ci "$CASE_DIR/s1" 42 --max-wait 900
    n1=$(fetches)
    RUN_SLEEP=: run_ci "$CASE_DIR/s2" 42 --max-wait 900
    n2=$(fetches)
    if [ "$n2" -eq "$n1" ]; then pass "10h a second run inside the TTL costs no rollup fetch ($n1 -> $n2)"; else fail "10h reuse" "fetches $n1 -> $n2, want no new rollup fetch inside the TTL"; fi

    # N concurrent runs share fetches.
    new_case
    printf 'pass\tunit-tests\n' > "$CASE_DIR/rows"
    for i in 1 2 3 4 5; do RUN_SLEEP=: run_ci "$CASE_DIR/n$i" 42 --max-wait 900 & done
    wait
    bad=0; for i in 1 2 3 4 5; do [ "$(cat "$CASE_DIR/n$i.rc")" -eq 0 ] || bad=$((bad+1)); done
    n=$(fetches)
    if [ "$bad" -eq 0 ]; then pass "10f 5 concurrent runs all green rc 0"; else fail "10f rc" "$bad runs not rc 0"; fi
    if [ "$n" -le 3 ]; then pass "10g 5 concurrent runs -> $n rollup fetches (uncached: >= 15)"; else fail "10g fetches" "$n fetches, want <= 3 (one per TTL window)"; fi
fi

# 11 — the escape hatch keeps the legacy watch.
new_case
printf 'pass\tunit-tests\n' > "$CASE_DIR/rows"
( cd "$CASE_DIR/cwd" && CHECK_CI_CACHE=0 CHECK_CI_SLEEP_CMD="${RUN_SLEEP:-fakesleep}" CHECK_CI_SETTLE=0 CR_APP=0 CR_PROFILE=none GH_BUDGET_PREFLIGHT=0 \
    ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 120} bash "$CHECK_CI" 42 --max-wait 900 >"$CASE_DIR/o.out" 2>"$CASE_DIR/o.err" ); rc=$?
if [ "$rc" -eq 0 ] && grep -q -- '--watch' "$CASE_DIR/calls.log"; then pass "11 CHECK_CI_CACHE=0 -> legacy gh pr checks --watch, rc 0"; else fail "11 legacy" "rc=$rc"; fi

echo
echo "check-ci-cache: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
