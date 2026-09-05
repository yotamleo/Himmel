#!/usr/bin/env bash
# test-bank-preflight.sh — HIMMEL-1841. Hermetic: fixture caches, stub producer.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$REPO/scripts/lib/bank-preflight.sh"
PASS=0; FAIL=0
W="$(mktemp -d -t bank-preflight.XXXXXX)"; trap 'rm -rf "$W"' EXIT

verdict() {
  printf '%s' "$1" > "$W/c.json"
  CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_SKIP_REFRESH=1 \
  CADENCE_BANK_LEDGER="$W/ledger.jsonl" CADENCE_BANK_LEG=testleg \
    bash "$SUT" </dev/null 2>"$W/err.log"
}
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }
NOW=$(date +%s)

check "below threshold -> PROCEED" PROCEED \
 "$(verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}")"
check "at threshold -> SKIPPED-BANK" SKIPPED-BANK \
 "$(verdict "{\"five_hour\":{\"utilization\":85},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}")"
check "mixed, seven_day over -> SKIPPED-BANK" SKIPPED-BANK \
 "$(verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":93},\"primaries_refreshed_at\":$NOW}")"
check "extra_usage high, primaries low -> PROCEED" PROCEED \
 "$(verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"extra_usage\":{\"utilization\":99},\"primaries_refreshed_at\":$NOW}")"
check "one primary null, other below -> PROCEED" PROCEED \
 "$(verdict "{\"five_hour\":{\"utilization\":null},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}")"
check "one primary null, other over -> SKIPPED-BANK" SKIPPED-BANK \
 "$(verdict "{\"five_hour\":{\"utilization\":null},\"seven_day\":{\"utilization\":91},\"primaries_refreshed_at\":$NOW}")"
check "both primaries null -> BANK-UNKNOWN" BANK-UNKNOWN \
 "$(verdict "{\"five_hour\":{\"utilization\":null},\"seven_day\":{\"utilization\":null},\"primaries_refreshed_at\":$NOW}")"
check "bare dot utilization -> BANK-UNKNOWN" BANK-UNKNOWN \
 "$(verdict "{\"five_hour\":{\"utilization\":\".\"},\"seven_day\":{\"utilization\":null},\"primaries_refreshed_at\":$NOW}")"
check "stamp absent -> BANK-STALE" BANK-STALE \
 "$(verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20}}")"
check "non-numeric max age -> BANK-UNKNOWN" BANK-UNKNOWN \
 "$(CADENCE_BANK_MAX_AGE=abc verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}")"
check "non-numeric max pct -> BANK-UNKNOWN" BANK-UNKNOWN \
 "$(CADENCE_BANK_MAX_PCT=abc verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}")"
check "valid max age, stamp too old -> BANK-STALE" BANK-STALE \
 "$(CADENCE_BANK_MAX_AGE=600 verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$((NOW-99999))}")"
check "non-integer stamp -> BANK-STALE" BANK-STALE \
 "$(verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":\"1.2.3\"}")"
# CADENCE_BANK_LEDGER is required here too — without it the SUT falls back to
# its default and this "hermetic" suite appends a row outside $W on every run.
check "missing cache -> BANK-UNKNOWN" BANK-UNKNOWN \
 "$(CADENCE_BANK_CACHE="$W/gone.json" CADENCE_BANK_SKIP_REFRESH=1 CADENCE_BANK_LEDGER="$W/ledger.jsonl" bash "$SUT" </dev/null 2>/dev/null)"

home_unset_out=$(env -u HOME -u CADENCE_BANK_LEDGER CADENCE_BANK_CACHE="$W/gone-home.json" \
  CADENCE_BANK_SKIP_REFRESH=1 bash "$SUT" </dev/null 2>/dev/null)
home_unset_rc=$?
case "$home_unset_out" in
  PROCEED|SKIPPED-BANK|BANK-STALE|BANK-UNKNOWN) home_unset_token=true ;;
  *) home_unset_token=false ;;
esac
if [ "$home_unset_rc" -eq 0 ] && [ "$home_unset_token" = true ]; then
  PASS=$((PASS+1)); echo "ok - HOME unset still yields a verdict"
else
  FAIL=$((FAIL+1)); echo "FAIL - HOME unset returned rc=$home_unset_rc output='$home_unset_out'"
fi

# Ledger row written
if grep -q '"verdict":"PROCEED"' "$W/ledger.jsonl" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - ledger row written"
else
  FAIL=$((FAIL+1)); echo "FAIL - no ledger row"
fi

# Ledger preserves whether the verdict used one primary or both.
rm -f "$W/ledger.jsonl"
verdict "{\"five_hour\":{\"utilization\":null},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}" >/dev/null
single_degraded=false; grep -q '"degraded":true' "$W/ledger.jsonl" && single_degraded=true
rm -f "$W/ledger.jsonl"
verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}" >/dev/null
two_healthy=false; grep -q '"degraded":false' "$W/ledger.jsonl" && two_healthy=true
if [ "$single_degraded" = true ] && [ "$two_healthy" = true ]; then
  PASS=$((PASS+1)); echo "ok - ledger records degraded state"
else
  FAIL=$((FAIL+1)); echo "FAIL - ledger does not record degraded state"
fi

future=$(( $(date +%s) + 86400 ))
printf '%s' "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$future}" > "$W/c.json"
future_out=$(CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_SKIP_REFRESH=1 \
  CADENCE_BANK_LEDGER="$W/ledger.jsonl" bash "$SUT" 2>/dev/null || true)
if [ "$future_out" = "BANK-STALE" ]; then
  PASS=$((PASS+1)); echo "ok - future-dated stamp is stale"
else
  FAIL=$((FAIL+1)); echo "FAIL - future-dated stamp did not yield BANK-STALE"
fi

# Held-open stdin via a FIFO, refresh ENABLED against a stub producer that reads
# stdin. A FIFO opened read-write never EOFs and has no writer to wait on, so a
# correct SUT returns at once and only a blocked one pays the timeout. This
# replaces `sleep N | timeout M`: sleep itself bounds stdin, so no timeout value
# can distinguish a correct SUT from one blocked on stdin. The watchdog is
# bash 3.2-compatible; GNU timeout is absent on macOS and Windows timeout.exe
# has incompatible semantics.
watchdog_after_25s() {
  local watched_pid="$1" sleeper_pid
  sleep 25 &
  sleeper_pid=$!
  trap 'kill "$sleeper_pid" 2>/dev/null; wait "$sleeper_pid" 2>/dev/null; exit 0' TERM INT
  wait "$sleeper_pid"
  kill -TERM "-$watched_pid" 2>/dev/null
}

stub="$W/prod.sh"; printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' > "$stub"; chmod +x "$stub"
printf '%s' "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}" > "$W/c.json"
# Monitor mode gives the SUT a dedicated process group so the watchdog also
# terminates a blocked producer descendant, not just its waiting parent shell.
set -m
if mkfifo "$W/fifo" 2>/dev/null; then
  exec 3<>"$W/fifo"
  CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_PRODUCER="$stub" \
    CADENCE_BANK_LEDGER="$W/ledger.jsonl" bash "$SUT" <&3 >/dev/null 2>&1 &
  sut_pid=$!
else
  # Fallback where mkfifo is unavailable: keep stdin open with a separate holder.
  (
    set +m
    exec 4< <(sleep 60)
    holder_pid=$!
    CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_PRODUCER="$stub" \
      CADENCE_BANK_LEDGER="$W/ledger.jsonl" bash "$SUT" <&4 >/dev/null 2>&1
    rc=$?
    exec 4<&-
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
    exit "$rc"
  ) &
  sut_pid=$!
fi
set +m
watchdog_after_25s "$sut_pid" &
watchdog_pid=$!
if wait "$sut_pid"; then rc=0; else rc=$?; fi
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
[ -e "$W/fifo" ] && exec 3>&-
if [ "$rc" -eq 0 ]; then PASS=$((PASS+1)); echo "ok - does not block on held-open stdin"
else FAIL=$((FAIL+1)); echo "FAIL - blocked on held-open stdin (missing </dev/null?)"; fi

echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
