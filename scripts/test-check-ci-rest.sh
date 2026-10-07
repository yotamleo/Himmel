#!/usr/bin/env bash
# HIMMEL-4857: real cache/watch against a call-counting gh seam, no live API.
# Breaks caught: unconditional REST reads, wrong-budget sleeps, unbounded
# fallback churn, stale/malformed conditional data becoming a green verdict.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/check-ci-rest.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CASE/calls"
case " $* " in
    *' -i graphql '*) printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: %s\r\nX-Ratelimit-Reset: 1000003600\r\n\r\n{"data":{}}\n' "${ACTUAL_GQL:-${GQL:-5000}}"; exit 0 ;;
esac
case "$1 $2" in
    'pr view') echo sha1; exit 0 ;;
    'pr checks')
        if [ "${GQL_ERROR:-0}" = 2 ]; then printf 'pass\tunit\n'; echo 'GraphQL unavailable' >&2; exit 1; fi
        [ "${GQL_ERROR:-0}" = 0 ] || { echo 'GraphQL unavailable' >&2; exit 1; }
        printf 'pass\tunit\n'; exit 0 ;;
esac
case " $* " in
    *' rate_limit '*) printf '%s 1000003600 %s 1000003600\n' "${CORE:-5000}" "${GQL:-5000}"; exit 0 ;;
    *'/check-runs?'*) body='{"total_count":1,"check_runs":[{"id":1,"name":"unit","status":"completed","conclusion":"success"}]}' ;;
    *'/status?'*) body='{"total_count":1,"statuses":[{"context":"lint","state":"success"}]}' ;;
    *) echo 'unexpected API call' >&2; exit 1 ;;
esac
[ "${REST_ERROR:-0}" = 0 ] || { echo 'REST unavailable' >&2; exit 1; }
if [ "${MALFORMED:-0}" = 1 ]; then body='{"total_count":1,"check_runs":[]}'; fi
if [ "${PAGED:-0}" = 1 ]; then body='{"total_count":101,"check_runs":[]}'; fi
case " $* " in
    *'If-None-Match:'*) printf 'HTTP/2.0 304 Not Modified\r\nETag: "v1"\r\n\r\n'; printf '304\n' >> "$CASE/responses" ;;
    *) printf 'HTTP/2.0 200 OK\r\nETag: "v1"\r\n\r\n%s\n' "$body"; printf '200\n' >> "$CASE/responses" ;;
esac
SH
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH" GH_REPO=octo/demo CHECK_CI_API_FLOOR=300
export GH_BUDGET_JITTER_MAX=0
fake_sleep() { printf '%s\n' "$1" >> "$CASE/sleeps"; }
export -f fake_sleep
export CIC_SLEEP_CMD=fake_sleep CHECK_CI_WATCH_SLEEP_CMD=fake_sleep
# shellcheck source=scripts/lib/gh-ci-cache.sh
. "$HERE/lib/gh-ci-cache.sh"
new_case() {
    CASE=$(mktemp -d "$ROOT/case.XXXXXX") || exit 1; export CASE
    : > "$CASE/calls"; : > "$CASE/responses"; : > "$CASE/sleeps"
    printf '1000000000\n' > "$CASE/clock"
    export CIC_CLOCK_FILE="$CASE/clock" CHECK_CI_CACHE_DIR="$CASE/cache"
    unset CORE GQL REST_ERROR GQL_ERROR MALFORMED PAGED ACTUAL_GQL
    cic_init 42 sha1 || exit 1
}
count() { grep -c -- "$1" "$CASE/calls" || true; }

new_case
for n in 0 1 2 3 4 5 6 7 8 9; do
    printf '%s\n' "$((1000000000 + n * 61))" > "$CASE/clock"
    cic_get 60 || bad "round $n could not read checks"
    [ "$CIC_ROWS" = $'pass\tunit\npass\tlint' ] || bad "round $n lost REST rollup"
done
full=$(grep -c '^200$' "$CASE/responses" || true)
conditional=$(grep -c '^304$' "$CASE/responses" || true)
if [ "$full/$conditional" = 2/18 ] && [ "$(count 'pr checks')" = 0 ]; then
    ok '10 rounds: one full two-endpoint REST snapshot, nine conditional snapshots, no GraphQL checks'
else bad "10-round fetch budget: full=$full conditional=$conditional GraphQL=$(count 'pr checks')"; fi
printf 'measurement: rounds=10 GraphQL=%s REST-full=%s REST-304=%s\n' "$(count 'pr checks')" "$full" "$conditional"

new_case
export GQL=0
cic_get 60; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$CASE/sleeps" ] && [ "$(count 'pr checks')" = 0 ]; then ok 'exhausted GraphQL continues on REST without sleep'; else bad 'exhausted GraphQL stalled REST'; fi

new_case
export CORE=0
cic_get 60; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$CASE/sleeps" ] && [ "$(count 'pr checks')" = 1 ] && [ "$(count '/check-runs?')" = 0 ]; then ok 'low core continues on GraphQL without sleep'; else bad 'low core did not rotate'; fi

new_case
export REST_ERROR=1
cic_get 60; rc=$?
if [ "$rc" = 0 ] && [ "$(count 'pr checks')" = 1 ]; then ok 'unreadable REST falls back once to GraphQL'; else bad 'REST fallback failed'; fi

new_case
export REST_ERROR=1 GQL_ERROR=1
OUT=$(bash "$HERE/lib/check-ci-watch.sh" 42 2>&1); rc=$?
if [ "$rc" = 2 ] && [ "$(count 'pr checks')" = 1 ] && printf '%s' "$OUT" | grep -q 'REST unavailable.*GraphQL unavailable'; then ok 'both APIs unreadable exits 2, fallback churn capped'; else bad "both APIs unreadable rc=$rc"; fi

new_case
export REST_ERROR=1 GQL_ERROR=2
OUT=$(bash "$HERE/lib/check-ci-watch.sh" 42 2>&1); rc=$?
if [ "$rc" = 2 ]; then ok 'GraphQL error with valid stdout cannot replace unreadable REST with green'; else bad 'GraphQL partial output falsely certified green'; fi

new_case
export CORE=0 GQL=0 CIC_MAX_WAIT=1
cic_get 60; rc=$?
unset CIC_MAX_WAIT
if [ "$rc" = 2 ] && [ ! -s "$CASE/sleeps" ] && [ "$(count 'pr checks')" = 0 ] && [ "$(count '/check-runs?')" = 0 ]; then ok 'both depleted budgets beyond deadline refuse paid reads'; else bad 'depleted budgets were spent beyond deadline'; fi

new_case
export REST_ERROR=1 ACTUAL_GQL=0
cic_get 60; rc=$?
if [ "$rc" != 0 ] && [ "$(count 'pr checks')" = 0 ] && [ ! -s "$CASE/sleeps" ]; then ok 'fallback uses real GraphQL header budget, not healthy REST rate_limit report'; else bad 'misreported GraphQL budget was spent'; fi

new_case
export MALFORMED=1 GQL_ERROR=1
cic_get 60; rc=$?
if [ "$rc" != 0 ] && [ -z "$CIC_ROWS" ]; then ok 'incomplete REST response cannot certify green'; else bad 'incomplete REST response was green'; fi

new_case
export PAGED=1
cic_get 60; rc=$?
if [ "$rc" = 0 ] && [ "$(count 'pr checks')" = 1 ]; then ok 'truncated REST page falls back instead of dropping checks'; else bad 'pagination ceiling failed'; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
