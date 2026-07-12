#!/usr/bin/env bash
# Smoke tests for the WS9/HIMMEL-654 Task 3 Claude in-hook quota-gauge writer
# grafted into scripts/hooks/auto-arm-on-cap.sh.
#
# The writer is a best-effort, FAIL-OPEN observation: at a fresh-cache
# threshold trip it appends one lane:"claude" source:"arm-threshold" row; at
# the wedged/stale (usage INVISIBLE) escalation it appends one
# source:"invisible" row; between trips it writes nothing (dim-lane honesty).
# A ledger-append failure MUST NOT touch the watchdog's exit path.
#
# Reuses the auto-arm smoke scaffolding (arm stub via AUTO_ARM_BIN, cache via
# AUTO_ARM_CACHE) and adds a HIMMEL_QUOTA_GAUGE_LEDGER tmp ledger. Never touches
# the real scheduler, the real cache, or the real ledger.
set -u -o pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/auto-arm-on-cap.sh"
# Repo root, so an out-of-tree baseline copy (T24) still resolves the hook's
# sibling libs via the hook's $CLAUDE_PROJECT_DIR/scripts/lib fallback.
PROJ_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

assert_rc() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc (expected rc=$expected, got rc=$actual)"; fail=$((fail+1))
    fi
}

assert_grep() {
    local desc="$1" pattern="$2" file="$3"
    if [ -f "$file" ] && grep -q -- "$pattern" "$file"; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc (pattern '$pattern' not in $file)"; fail=$((fail+1))
    fi
}

assert_no_grep() {
    local desc="$1" pattern="$2" file="$3"
    if [ ! -f "$file" ] || ! grep -q -- "$pattern" "$file"; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc (unexpected '$pattern' in $file)"; fail=$((fail+1))
    fi
}

assert_lines() {
    local desc="$1" expected="$2" file="$3" actual=0
    [ -f "$file" ] && actual=$(grep -c '' "$file" 2>/dev/null || echo 0)
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc (expected $expected lines, got $actual)"; fail=$((fail+1))
    fi
}

# Shared stub arm (always succeeds unless ARM_STUB_RC overrides).
ARM_STUB="$TMP/arm-stub.sh"
ARM_LOG="$TMP/arm-calls.log"
cat > "$ARM_STUB" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${ARM_LOG_PATH}"
exit "${ARM_STUB_RC:-0}"
EOF
chmod +x "$ARM_STUB"

write_cache() {
    # $1=path $2=five_hour util $3=seven_day util $4=five_hour resets_at (optional)
    local resets="${4:-2026-06-10T13:30:00+00:00}"
    cat > "$1" <<EOF
{"five_hour":{"utilization":$2,"resets_at":"$resets"},"seven_day":{"utilization":$3,"resets_at":"2026-06-13T09:00:00+00:00"}}
EOF
}

# Fresh cache with NO resets_at on either window (forces the hook's
# "unknown"/bucket<N> substitution — reset_at must map to null, never copied).
write_cache_no_resets() {
    cat > "$1" <<EOF
{"five_hour":{"utilization":$2},"seven_day":{"utilization":$3}}
EOF
}

HANDOVER_TEST_DIR="$TMP/handovers"; mkdir -p "$HANDOVER_TEST_DIR"
STDERR_LOG="$TMP/stderr.log"

run_hook() {
    # $1=state dir $2=cache path $3=ledger path ; extra env via prefix vars
    AUTO_ARM_STATE_DIR="$1" AUTO_ARM_CACHE="$2" HIMMEL_QUOTA_GAUGE_LEDGER="$3" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
}

echo "Test T7: fresh-cache threshold trip → one claude arm-threshold row (used_pct, window=5h, real reset_at, tier=null)"
S="$TMP/s7"; mkdir -p "$S"
C="$TMP/c7.json"; write_cache "$C" 93 14 "2026-06-10T13:30:00+00:00"
L="$TMP/ledger7.jsonl"
run_hook "$S" "$C" "$L"
assert_rc "tripped run still exits 2 (one-shot block unchanged)" 2 $?
assert_lines "exactly one ledger row" 1 "$L"
assert_grep "row is lane claude" '"lane":"claude"' "$L"
assert_grep "row source is arm-threshold" '"source":"arm-threshold"' "$L"
assert_grep "used_pct is the tripping window's utilization (93, not 100)" '"used_pct":93' "$L"
assert_grep "window mapped five_hour -> 5h" '"window":"5h"' "$L"
assert_grep "reset_at is the real ISO instant" '"reset_at":"2026-06-10T13:30:00+00:00"' "$L"
assert_grep "tier is null (hook exposes no tier)" '"tier":null' "$L"

echo "Test T7b: seven_day binding window maps to weekly"
S="$TMP/s7b"; mkdir -p "$S"
C="$TMP/c7b.json"; write_cache "$C" 14 95 "2026-06-10T13:30:00+00:00"
L="$TMP/ledger7b.jsonl"
run_hook "$S" "$C" "$L"
assert_rc "seven_day trip exits 2" 2 $?
assert_grep "window mapped seven_day -> weekly" '"window":"weekly"' "$L"
assert_grep "used_pct is seven_day utilization (95)" '"used_pct":95' "$L"

echo "Test T25: threshold trip with NO resets_at → reset_at null, never 'unknown'/'bucket'"
S="$TMP/s25"; mkdir -p "$S"
C="$TMP/c25.json"; write_cache_no_resets "$C" 93 14
L="$TMP/ledger25.jsonl"
run_hook "$S" "$C" "$L"
assert_rc "no-resets trip exits 2" 2 $?
assert_lines "exactly one ledger row" 1 "$L"
assert_grep "arm-threshold row written" '"source":"arm-threshold"' "$L"
assert_grep "reset_at is null" '"reset_at":null' "$L"
assert_no_grep "literal 'unknown' never leaks into the row" 'unknown' "$L"
assert_no_grep "bucket token never leaks into the row" 'bucket' "$L"

echo "Test T8: wedged/stale cache (usage INVISIBLE) → one source:invisible claude row, used_pct null"
if touch -d '@1' "$TMP/probe-touch" 2>/dev/null; then
    S="$TMP/s8"; mkdir -p "$S"
    C="$TMP/c8.json"; write_cache "$C" 30 14
    touch -d '@1' "$C"
    L="$TMP/ledger8.jsonl"
    AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" HIMMEL_QUOTA_GAUGE_LEDGER="$L" \
        AUTO_ARM_STALE_MIN_CHECKS=1 AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
        HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
        bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
    assert_rc "wedge escalation still exits 2" 2 $?
    assert_lines "exactly one ledger row" 1 "$L"
    assert_grep "row is lane claude" '"lane":"claude"' "$L"
    assert_grep "row source is invisible" '"source":"invisible"' "$L"
    assert_grep "used_pct is null (usage unobservable)" '"used_pct":null' "$L"
    assert_grep "window is null on the invisible row" '"window":null' "$L"
    assert_grep "reset_at is null on the invisible row" '"reset_at":null' "$L"
else
    echo "  SKIP  T8 (touch -d unsupported on this platform)"
fi

echo "Test T9b: one-shot — a session pinned above threshold appends ONE arm-threshold row across repeated checks"
S="$TMP/s9b"; mkdir -p "$S"
C="$TMP/c9b.json"; write_cache "$C" 95 14 "2026-06-10T13:30:00+00:00"
L="$TMP/ledger9b.jsonl"
run_hook "$S" "$C" "$L"                       # 1st real check: trips, one row, arms, fired-marker set
assert_rc "first tripping check exits 2" 2 $?
rm -f "$S/auto-arm-last-check"                # defeat the throttle, keep the fired marker
run_hook "$S" "$C" "$L"                       # 2nd real check: one-shot guard exits before the writer
assert_rc "second tripping check exits 0 (one-shot held)" 0 $?
assert_lines "still exactly one arm-threshold row (no per-check spam)" 1 "$L"

echo "Test T-lib: missing ledger lib — the command -v guard holds, hook still exits at its baseline (no crash, no row)"
# Isolate a hook copy whose sibling lib dir carries py-armor.sh (so the watchdog
# still works) but NOT quota-gauge-ledger.sh, and point CLAUDE_PROJECT_DIR nowhere,
# so quota_gauge_append is never defined. Exercises fail-open branch (a): a missing
# lib must not break the watchdog (distinct from T24's append-failure branch (b)).
LIBLESS="$TMP/libless"; mkdir -p "$LIBLESS/hooks" "$LIBLESS/lib"
cp "$HOOK" "$LIBLESS/hooks/"
cp "$(dirname "$HOOK")/../lib/py-armor.sh" "$LIBLESS/lib/"
S="$TMP/slib"; mkdir -p "$S"
C="$TMP/clib.json"; write_cache "$C" 95 14 "2026-06-10T13:30:00+00:00"
L="$TMP/ledgerlib.jsonl"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" HIMMEL_QUOTA_GAUGE_LEDGER="$L" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="$TMP/no-such-projdir" \
    bash "$LIBLESS/hooks/auto-arm-on-cap.sh" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "missing-lib trip still exits 2 (watchdog unbroken)" 2 $?
assert_lines "no ledger row when the append helper is undefined (guard held)" 0 "$L"

echo "Test T9: fresh cache below threshold (no trip) → NO claude row written (dim-lane honesty)"
S="$TMP/s9"; mkdir -p "$S"
C="$TMP/c9.json"; write_cache "$C" 30 14
L="$TMP/ledger9.jsonl"
run_hook "$S" "$C" "$L"
assert_rc "below-threshold run exits 0" 0 $?
assert_lines "no ledger rows on a no-trip check" 0 "$L"

echo "Test T24: fail-open — an UNWRITABLE ledger must not change the hook's exit code vs a WS9-absent baseline"
# Baseline = the pre-patch watchdog, produced by stripping the sentinel-delimited
# WS9 blocks from the patched hook (no permanent kill-switch knob is added).
BASELINE="$TMP/auto-arm-baseline.sh"
awk '
  /# >>> WS9-QUOTA-GAUGE/ { skip=1 }
  /# <<< WS9-QUOTA-GAUGE/ { skip=0; next }
  !skip { print }
' "$HOOK" > "$BASELINE"
chmod +x "$BASELINE"
# Sanity: the strip actually removed something and left a runnable script.
if [ "$(grep -c '' "$BASELINE")" -lt "$(grep -c '' "$HOOK")" ] && [ "$(grep -c '' "$BASELINE")" -gt 100 ]; then
    echo "  PASS  baseline is a smaller-but-substantial pre-patch hook"; pass=$((pass+1))
else
    echo "  FAIL  baseline strip looks wrong (baseline=$(grep -c '' "$BASELINE") hook=$(grep -c '' "$HOOK"))"; fail=$((fail+1))
fi
# The WS9 wrapper name is unambiguous — a pre-existing header comment mentions
# the word "quota-gauge" generically, so match the added helper, not the noun.
if ! grep -q 'quota_gauge_note_claude\|WS9-QUOTA-GAUGE' "$BASELINE"; then
    echo "  PASS  baseline contains no WS9 quota-gauge code"; pass=$((pass+1))
else
    echo "  FAIL  baseline still references WS9 quota-gauge code"; fail=$((fail+1))
fi

run_with_hook() {  # $1=hook script $2=state dir $3=cache $4=ledger  -> echoes rc
    local hk="$1" sd="$2" ca="$3" ld="$4"
    # CLAUDE_PROJECT_DIR=repo root: the in-tree HOOK resolves libs via its own
    # dir; the out-of-tree stripped BASELINE resolves them via this fallback.
    # Both compared under identical env so any rc delta is the WS9 patch alone.
    AUTO_ARM_STATE_DIR="$sd" AUTO_ARM_CACHE="$ca" HIMMEL_QUOTA_GAUGE_LEDGER="$ld" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="$PROJ_ROOT" \
    bash "$hk" </dev/null >/dev/null 2>/dev/null
    echo $?
}

# Unwritable ledger: point HIMMEL_QUOTA_GAUGE_LEDGER at a DIRECTORY so the
# append's `printf >> "$path"` fails.
UNWRIT="$TMP/unwritable-ledger-dir"; mkdir -p "$UNWRIT"

# Trip input (util 95 -> exit 2 expected).
Ct="$TMP/c24-trip.json"; write_cache "$Ct" 95 14
St1="$TMP/s24t-patched"; mkdir -p "$St1"
St2="$TMP/s24t-base"; mkdir -p "$St2"
rc_patched_trip=$(run_with_hook "$HOOK" "$St1" "$Ct" "$UNWRIT")
rc_base_trip=$(run_with_hook "$BASELINE" "$St2" "$Ct" "$UNWRIT")
assert_rc "trip: patched rc == baseline rc (fail-open, unwritable ledger)" "$rc_base_trip" "$rc_patched_trip"
assert_rc "trip: baseline rc is the expected block (2)" 2 "$rc_base_trip"

# No-trip input (util 30 -> exit 0 expected).
Cn="$TMP/c24-notrip.json"; write_cache "$Cn" 30 14
Sn1="$TMP/s24n-patched"; mkdir -p "$Sn1"
Sn2="$TMP/s24n-base"; mkdir -p "$Sn2"
rc_patched_notrip=$(run_with_hook "$HOOK" "$Sn1" "$Cn" "$UNWRIT")
rc_base_notrip=$(run_with_hook "$BASELINE" "$Sn2" "$Cn" "$UNWRIT")
assert_rc "no-trip: patched rc == baseline rc (fail-open, unwritable ledger)" "$rc_base_notrip" "$rc_patched_notrip"
assert_rc "no-trip: baseline rc is the expected allow (0)" 0 "$rc_base_notrip"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
