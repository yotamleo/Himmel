#!/usr/bin/env bash
# HIMMEL-4856: real run-mode entrypoint against a gh shim; no live GitHub.
# Catches false green on pending/unknown jobs, swallowed reads, unbounded waits,
# per-waiter fetches, wrong job selection, and spending the wrong rate bucket.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/check-ci-run.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; printf '%s\n' "${OUT:-}"; FAIL=$((FAIL + 1)); }
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$CASE/calls"
if [ "$1" = api ] && [ "${4:-}" = rate_limit ]; then
    now=$(cat "$CASE/clock")
    [ "${BUDGET_SLOW:-0}" = 0 ] || sleep "$BUDGET_SLOW"
    printf '%s %s %s %s\n' "${CORE:-5000}" "$((now + ${BUDGET_RESET:-20}))" "${GQL:-5000}" "$((now + 20))"
    exit 0
fi
if [ "$1 $2" != 'run view' ] || [ "$3" != 123 ]; then
    echo "unexpected gh call: $*" >&2; exit 1
fi
n=$(grep -c '^run view' "$CASE/calls")
if [ "$n" -gt "${SLOW_AFTER:-0}" ] && [ "${SLOW:-0}" != 0 ]; then sleep "$SLOW"; fi
if [ -f "$CASE/response.$n" ]; then cat "$CASE/response.$n"; else cat "$CASE/response"; fi
if [ "${GH_ERROR:-0}" = 1 ]; then echo 'network unreadable' >&2; exit 1; fi
SH
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH" GH_REPO=octo/demo
export CHECK_CI_WATCH_INTERVAL=2 CHECK_CI_WATCH_INTERVAL_MAX=8
export CHECK_CI_CACHE_TTL=1 CHECK_CI_DECIDE_TTL=1 GH_BUDGET_JITTER_MAX=0
fake_sleep() {
    local now; now=$(cat "$CASE/clock")
    printf '%s\n' "$((now + $1))" > "$CASE/clock"
    printf '%s\n' "$1" >> "$CASE/sleeps"
}
export -f fake_sleep
export CHECK_CI_WATCH_SLEEP_CMD=fake_sleep
new_case() {
    CASE=$(mktemp -d "$ROOT/case.XXXXXX") || exit 1
    export CASE
    printf '1000000000\n' > "$CASE/clock"
    : > "$CASE/calls"; : > "$CASE/sleeps"
    export CIC_CLOCK_FILE="$CASE/clock" CHECK_CI_CACHE_DIR="$CASE/cache"
    export CHECK_CI_RUN_HEARTBEAT="$CASE/heartbeat"
    unset CORE GQL SLOW SLOW_AFTER BUDGET_SLOW BUDGET_RESET GH_ERROR CHECK_CI_DISTINCT_DEADLINE
}
# Complete fixtures: gh run view --json databaseId,status,conclusion,jobs.
fixture() {
    printf '{"databaseId":123,"status":"%s","conclusion":"%s","jobs":[{"databaseId":456,"name":"unit","status":"%s","conclusion":"%s"}]}\n' "$1" "$2" "$3" "$4"
}
run() { OUT=$(bash "$HERE/check-ci.sh" "$@" 2>&1); RC=$?; }
expect_rc() { if [ "$RC" = "$1" ]; then ok "$2"; else bad "$2 (rc=$RC want $1)"; fi; }
expect_text() { if printf '%s\n' "$OUT" | grep -F -- "$1" >/dev/null; then ok "$2"; else bad "$2"; fi; }

echo test-check-ci-run.sh
new_case
fixture in_progress '' in_progress '' > "$CASE/response.1"
fixture completed success completed success > "$CASE/response"
run --run 123 --max-wait 10
expect_rc 0 'pending then success'
if [ "$(grep -c '^run view' "$CASE/calls")" -eq 2 ]; then ok 'pending must poll, terminal confirmation uses cache'; else bad 'pending must poll before green'; fi
if grep -Eq '^hb=[0-9]+ pid=[0-9]+ key=[^ ]+ tick=ok state=exited exit=0$' "$CASE/heartbeat" 2>/dev/null; then ok 'heartbeat records terminal state'; else bad 'heartbeat records terminal state'; fi

new_case
fixture completed failure completed failure > "$CASE/response"
run --run 123 --max-wait 10
expect_rc 1 'failed job'
expect_text unit 'names the failed job'
expect_text 'gh run view 123 --log-failed' 'prints the run log command'

new_case
fixture completed success completed success > "$CASE/response"
export GH_ERROR=1
run --run 123 --max-wait 10
expect_rc 2 'gh failure with valid stdout is unreadable, not green'
expect_text 'network unreadable' 'preserves gh diagnostic'

new_case
printf '{"jobs":[]}\n' > "$CASE/response"
run --run 123 --max-wait 10
expect_rc 2 'malformed response cannot evaluate'

new_case
fixture in_progress '' in_progress '' > "$CASE/response"
run --run 123 --max-wait 5
expect_rc 2 'deadline with pending work'
expect_text DEADLINE-PENDING 'names deadline verdict'
if [ "$(cat "$CASE/clock")" -eq 1000000005 ]; then ok 'sleep clamps to remaining deadline'; else bad 'sleep clamps to remaining deadline'; fi

new_case
fixture in_progress '' in_progress '' > "$CASE/response"
export CHECK_CI_DISTINCT_DEADLINE=1
run --run 123 --max-wait 3
expect_rc 7 'distinct deadline exit remains opt-in'

new_case
fixture in_progress '' completed success > "$CASE/response"
run --run 123 --job unit --max-wait 10
expect_rc 0 'selected job succeeds while workflow still runs'

new_case
fixture completed success completed success > "$CASE/response"
run --run 123 --job missing --max-wait 10
expect_rc 2 'missing job in completed workflow cannot evaluate'

new_case
fixture completed cancelled completed cancelled > "$CASE/response"
run --run 123 --max-wait 10
expect_rc 1 'cancelled workflow is not green'

new_case
fixture completed mystery completed mystery > "$CASE/response"
run --run 123 --max-wait 10
expect_rc 2 'unknown conclusion fails closed'

new_case
fixture completed success completed success > "$CASE/response"
export SLOW=0.3 CHECK_CI_CACHE_TTL=60 CHECK_CI_DECIDE_TTL=60
bash "$HERE/check-ci.sh" --run 123 --max-wait 10 > "$CASE/out.1" 2>&1 & p1=$!
bash "$HERE/check-ci.sh" --run 123 --job unit --max-wait 10 > "$CASE/out.2" 2>&1 & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
OUT=$(cat "$CASE/out.1" "$CASE/out.2")
if [ "$r1/$r2" = 0/0 ] && [ "$(grep -c '^run view' "$CASE/calls")" -eq 1 ]; then ok 'two concurrent run/job waiters share one fetch'; else bad "concurrent waiters rc=$r1/$r2 must share one fetch"; fi
export CHECK_CI_CACHE_TTL=1 CHECK_CI_DECIDE_TTL=1

new_case
fixture completed success completed success > "$CASE/response"
export GQL=0
run --run 123 --max-wait 10
expect_rc 0 'drained GraphQL does not stall REST run reads'
if [ ! -s "$CASE/sleeps" ]; then ok 'no GraphQL budget sleep'; else bad 'wrong bucket caused sleep'; fi

new_case
fixture completed success completed success > "$CASE/response"
export CORE=0
run --run 123 --max-wait 40
expect_rc 0 'core budget preflight waits before REST fetch'
if [ -s "$CASE/sleeps" ]; then ok 'core budget wait uses sleep seam'; else bad 'missing core budget wait'; fi

new_case
fixture completed success completed success > "$CASE/response"
for args in '--job unit' '--run nope' '--run 123 42' '--run 123 --threads-only' '--run 123 --run 123' '--run 18446744073709551739'; do
    # Intentional splitting of literal argument fixtures.
    # shellcheck disable=SC2086
    run $args
    expect_rc 64 "invalid argument combination: $args"
done
new_case
fixture completed success completed success > "$CASE/response"
export SLOW=2
run --run 123 --max-wait 1
expect_rc 2 'stalled gh read stays inside max-wait and cannot evaluate'

new_case
fixture completed success completed success > "$CASE/response"
fixture in_progress '' in_progress '' > "$CASE/response.1"
run --run 123 --job missing --max-wait 10
expect_rc 2 'missing job waits for registration then refuses completed workflow'
if [ "$(grep -c '^run view' "$CASE/calls")" -eq 2 ]; then ok 'unregistered job was pending, not immediate error'; else bad 'missing job registration was not polled'; fi

new_case
fixture completed success completed success > "$CASE/response"
export GH_REPO=octo/other
run --run 123 --max-wait 10
export GH_REPO=octo/demo
run --run 123 --max-wait 10
if [ "$(grep -c '^run view' "$CASE/calls")" -eq 2 ]; then ok 'same run id in another repo cannot reuse cached green'; else bad 'repository missing from cache key'; fi

# Review codex-1: a slow budget probe must not leave a stale sleep bound.
new_case
fixture completed success completed success > "$CASE/response"
export CORE=0 BUDGET_SLOW=4 BUDGET_RESET=2 CHECK_CI_WATCH_SLEEP_CMD=sleep
started=$SECONDS
run --run 123 --max-wait 6
expect_rc 2 'reset beyond remaining budget cannot evaluate'
if [ "$((SECONDS - started))" -le 6 ]; then ok 'budget request time is deducted before reset sleep'; else bad 'stale budget wait exceeded max-wait'; fi
export CHECK_CI_WATCH_SLEEP_CMD=fake_sleep

# Review codex-2: timeout during a re-read after pending is a pending deadline,
# not an ordinary network failure. An initial unreadable read still exits 2.
new_case
fixture in_progress '' in_progress '' > "$CASE/response.1"
fixture completed success completed success > "$CASE/response"
unset CIC_CLOCK_FILE
export SLOW=4 SLOW_AFTER=1 CHECK_CI_WATCH_SLEEP_CMD=sleep CHECK_CI_DISTINCT_DEADLINE=1
run --run 123 --max-wait 3
expect_rc 7 'deadline during pending reread retains distinct deadline exit'
expect_text DEADLINE-PENDING 'pending reread timeout names the deadline'
export CHECK_CI_WATCH_SLEEP_CMD=fake_sleep

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
