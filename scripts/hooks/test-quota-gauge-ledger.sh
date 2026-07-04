#!/usr/bin/env bash
# Smoke test for scripts/lib/quota-gauge-ledger.sh (WS9/HIMMEL-654).
#
# Appends two rows via the bash twin, asserts exactly 2 whole
# JSON-parseable lines; the path resolver honors HIMMEL_QUOTA_GAUGE_LEDGER;
# the --emit CLI matches the canonical TS serialization (the authoritative
# bash half of the byte-identical contract, T22). No real $HOME writes.
set -u -o pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/../lib/quota-gauge-ledger.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

# assert_eq <desc> <expected> <actual>
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

LEDGER="$TMP/quota-gauge.jsonl"
export HIMMEL_QUOTA_GAUGE_LEDGER="$LEDGER"
# shellcheck source=../lib/quota-gauge-ledger.sh
# shellcheck disable=SC1091
. "$LIB"

quota_gauge_append "$(quota_gauge_row glm monitor-endpoint 62 5h 2026-07-04T14:00:00Z "live reading")"
quota_gauge_append "$(quota_gauge_row claude arm-threshold 93 5h "" "cap approached")"

if [ -f "$LEDGER" ]; then ok "ledger created at HIMMEL_QUOTA_GAUGE_LEDGER"; else bad "ledger missing"; fi

total=$(wc -l < "$LEDGER" | tr -d ' ')
assert_eq "exactly 2 lines" "2" "$total"

# Both lines whole + parseable (python3 — same parser the auto-arm watchdog
# depends on, so its availability is already a harness invariant).
parse=$(python3 -c 'import json,sys
n=0
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    o=json.loads(line)  # raises on a malformed/merged line
    assert o["v"]==1 and "lane" in o and "used_pct" in o
    n+=1
print(n)' < "$LEDGER" 2>/dev/null) || { bad "python3 parse failed"; echo "FAIL"; exit 1; }
assert_eq "both lines JSON-parseable, v=1, full schema" "2" "$parse"

# Path resolver honors the override.
assert_eq "resolver honors HIMMEL_QUOTA_GAUGE_LEDGER" "$LEDGER" "$(quota_gauge_ledger_path)"

# --emit prints one canonical row WITHOUT appending (byte-identical T22).
emit=$(bash "$LIB" --emit claude arm-threshold 93 5h 2026-07-04T14:00:00Z "cap approached" 2026-07-04T12:00:00Z)
expect='{"v":1,"ts":"2026-07-04T12:00:00Z","lane":"claude","source":"arm-threshold","used_pct":93,"window":"5h","reset_at":"2026-07-04T14:00:00Z","tier":null,"glm_peak":null,"note":"cap approached"}'
assert_eq "--emit canonical line (byte-identical)" "$expect" "$emit"

echo
if [ "$fail" = 0 ]; then echo "PASS ($pass checks)"; exit 0; else echo "FAIL ($fail failed)"; exit 1; fi
