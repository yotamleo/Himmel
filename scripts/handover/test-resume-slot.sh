#!/usr/bin/env bash
# Tests for scripts/handover/resume-slot.sh (HIMMEL-204).
# Cross-platform: pure bash + python3, no scheduler. Synthetic cache fixtures.
set -uo pipefail

SLOT="$(cd "$(dirname "$0")" && pwd)/resume-slot.sh"
[ -x "$SLOT" ] || chmod +x "$SLOT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then echo "PASS $label (rc=$actual)"
    else echo "FAIL $label — expected rc=$expected, got rc=$actual"; FAILED=$((FAILED+1)); fi
}
assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label — missing: $needle | got: $haystack"; FAILED=$((FAILED+1)) ;; esac
}
assert_true() {
    local label="$1" cond="$2"
    if [ "$cond" = "1" ]; then echo "PASS $label"; else echo "FAIL $label"; FAILED=$((FAILED+1)); fi
}
assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in *"$needle"*) echo "FAIL $label — unexpectedly contains: $needle"; FAILED=$((FAILED+1)) ;;
        *) echo "PASS $label" ;; esac
}

# Write a cache fixture with given utils + resets, fresh mtime (now).
# Usage: mk_cache <path> <five_util> <five_reset_iso> <seven_util> <seven_reset_iso>
mk_cache() {
    printf '{"five_hour":{"utilization":%s,"resets_at":"%s"},"seven_day":{"utilization":%s,"resets_at":"%s"}}' \
        "$2" "$3" "$4" "$5" > "$1"
}
# ISO 8601 UTC string for now + N seconds (python3).
iso_in() { python3 -c 'import sys,datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=int(sys.argv[1]))).isoformat())' "$1"; }

NOW=$(date +%s)

# ---------------------------------------------------------------------------
# T1: bank free (both windows below threshold) -> ASAP (now + buffer)
# ---------------------------------------------------------------------------
mk_cache "$TMP/free.json" 0.0 "$(iso_in 18000)" 21.0 "$(iso_in 604800)"
out=$(bash "$SLOT" --cache "$TMP/free.json" --max-age 0 --buffer-min 4 --emit all 2>&1); rc=$?
assert_rc "T1 free-bank exits 0" 0 "$rc"
assert_contains "T1 reason says bank free + ASAP" "bank free" "$out"
ep=$(printf '%s' "$out" | cut -f1)
# epoch must be in (now, now + 5min] — i.e. the +4m ASAP slot, allowing skew.
in_window=$(python3 -c 'import sys; n,e=int(sys.argv[1]),int(sys.argv[2]); print(1 if n < e <= n+360 else 0)' "$NOW" "$ep")
assert_true "T1 ASAP epoch ~ now+4m" "$in_window"

# ---------------------------------------------------------------------------
# T2: five_hour exhausted (>= threshold) -> wait for its reset
# ---------------------------------------------------------------------------
FIVE_RESET=$(iso_in 9000)   # 2.5h out
mk_cache "$TMP/five.json" 96.0 "$FIVE_RESET" 30.0 "$(iso_in 604800)"
out=$(bash "$SLOT" --cache "$TMP/five.json" --max-age 0 --emit all 2>&1); rc=$?
assert_rc "T2 five-exhausted exits 0" 0 "$rc"
assert_contains "T2 waits for five-hour reset" "wait for five-hour reset" "$out"
ep=$(printf '%s' "$out" | cut -f1)
match=$(python3 -c 'import sys,datetime; want=int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()); print(1 if abs(int(sys.argv[2])-want)<=1 else 0)' "$FIVE_RESET" "$ep")
assert_true "T2 epoch == five_hour reset" "$match"

# ---------------------------------------------------------------------------
# T3: both exhausted -> wait for the LATEST reset (seven_day here)
# ---------------------------------------------------------------------------
SEVEN_RESET=$(iso_in 200000)
mk_cache "$TMP/both.json" 99.0 "$(iso_in 9000)" 95.0 "$SEVEN_RESET"
out=$(bash "$SLOT" --cache "$TMP/both.json" --max-age 0 --emit reason 2>&1); rc=$?
assert_rc "T3 both-exhausted exits 0" 0 "$rc"
assert_contains "T3 waits for the latest (seven-day) reset" "wait for seven-day reset" "$out"

# ---------------------------------------------------------------------------
# T4: clock-skew — exhausted window whose reset already passed -> ASAP fallback
# ---------------------------------------------------------------------------
mk_cache "$TMP/skew.json" 99.0 "$(iso_in -600)" 10.0 "$(iso_in 604800)"
out=$(bash "$SLOT" --cache "$TMP/skew.json" --max-age 0 --emit reason 2>&1); rc=$?
assert_rc "T4 skew exits 0" 0 "$rc"
assert_contains "T4 past reset falls back to ASAP" "ASAP" "$out"

# ---------------------------------------------------------------------------
# T5: threshold boundary — util exactly == threshold counts as exhausted
# ---------------------------------------------------------------------------
mk_cache "$TMP/eq.json" 90.0 "$(iso_in 9000)" 10.0 "$(iso_in 604800)"
out=$(bash "$SLOT" --cache "$TMP/eq.json" --max-age 0 --threshold 90 --emit reason 2>&1)
assert_contains "T5 util == threshold is exhausted" "wait for five-hour reset" "$out"

# ---------------------------------------------------------------------------
# T6: missing cache -> rc 2
# ---------------------------------------------------------------------------
bash "$SLOT" --cache "$TMP/nope.json" --emit epoch >/dev/null 2>&1
assert_rc "T6 missing cache exits 2" 2 "$?"

# ---------------------------------------------------------------------------
# T7: stale cache (old mtime, default max-age) -> rc 2
# ---------------------------------------------------------------------------
mk_cache "$TMP/stale.json" 0.0 "$(iso_in 18000)" 0.0 "$(iso_in 604800)"
python3 -c 'import os,sys,time; os.utime(sys.argv[1],(time.time()-100000,time.time()-100000))' "$TMP/stale.json"
bash "$SLOT" --cache "$TMP/stale.json" --emit epoch >/dev/null 2>&1
assert_rc "T7 stale cache exits 2" 2 "$?"
# ...but --max-age 0 bypasses the freshness check.
bash "$SLOT" --cache "$TMP/stale.json" --max-age 0 --emit epoch >/dev/null 2>&1
assert_rc "T7b --max-age 0 bypasses staleness" 0 "$?"

# ---------------------------------------------------------------------------
# T8: bad args -> rc 1
# ---------------------------------------------------------------------------
bash "$SLOT" --emit bogus --cache "$TMP/free.json" --max-age 0 >/dev/null 2>&1
assert_rc "T8 bad --emit exits 1" 1 "$?"
bash "$SLOT" --threshold abc --cache "$TMP/free.json" --max-age 0 >/dev/null 2>&1
assert_rc "T8 bad --threshold exits 1" 1 "$?"

# ---------------------------------------------------------------------------
# T9: exhausted window with NULL resets_at -> fail loud (rc 2), NOT silent ASAP
# ---------------------------------------------------------------------------
printf '{"five_hour":{"utilization":99.0,"resets_at":null},"seven_day":{"utilization":10.0,"resets_at":"%s"}}' "$(iso_in 604800)" > "$TMP/nullreset.json"
err=$(bash "$SLOT" --cache "$TMP/nullreset.json" --max-age 0 --emit epoch 2>&1); rc=$?
assert_rc "T9 exhausted+null-reset exits 2" 2 "$rc"
assert_contains "T9 surfaces the unsafe-slot reason" "cannot pick a safe slot" "$err"

# ---------------------------------------------------------------------------
# T10: malformed (non-JSON) cache -> rc 2, clean ERR (no python traceback)
# ---------------------------------------------------------------------------
printf 'not json at all {' > "$TMP/bad.json"
err=$(bash "$SLOT" --cache "$TMP/bad.json" --max-age 0 --emit epoch 2>&1); rc=$?
assert_rc "T10 malformed JSON exits 2" 2 "$rc"
assert_contains "T10 clean ERR line" "ERR resume-slot: cannot parse usage cache" "$err"
assert_not_contains "T10 no python traceback leaks" "Traceback (most recent call last)" "$err"

# ---------------------------------------------------------------------------
# T11: structurally-empty but valid JSON ({}) -> schema-mismatch rc 2,
#      NOT a silent 0%-coerced ASAP.
# ---------------------------------------------------------------------------
printf '{}' > "$TMP/empty.json"
err=$(bash "$SLOT" --cache "$TMP/empty.json" --max-age 0 --emit epoch 2>&1); rc=$?
assert_rc "T11 schema-empty cache exits 2" 2 "$rc"
assert_contains "T11 surfaces schema mismatch" "schema mismatch" "$err"

# ---------------------------------------------------------------------------
# T12: only seven_day exhausted (five_hour has headroom) -> wait seven_day
# ---------------------------------------------------------------------------
mk_cache "$TMP/sevenonly.json" 10.0 "$(iso_in 9000)" 97.0 "$(iso_in 200000)"
out=$(bash "$SLOT" --cache "$TMP/sevenonly.json" --max-age 0 --emit reason 2>&1)
assert_contains "T12 single seven_day exhausted waits for its reset" "wait for seven-day reset" "$out"

# ---------------------------------------------------------------------------
# T13: wedged python3 stub (HIMMEL-249) — the verdict block must fail
#      BOUNDED + visible (armor kill rc), never hang the smart resolver.
# ---------------------------------------------------------------------------
if timeout --version 2>/dev/null | grep -qi coreutils; then
    mkdir -p "$TMP/wedged-bin"
    cat > "$TMP/wedged-bin/python3" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep 30
EOF
    chmod +x "$TMP/wedged-bin/python3"
    mk_cache "$TMP/wedge.json" 0.0 "$(iso_in 18000)" 21.0 "$(iso_in 604800)"
    start=$(date +%s)
    err=$(PATH="$TMP/wedged-bin:$PATH" PY_ARMOR_TIMEOUT=1 PY_ARMOR_KILL_AFTER=1 \
        bash "$SLOT" --cache "$TMP/wedge.json" --max-age 0 --emit epoch 2>&1 >/dev/null)
    rc=$?
    elapsed=$(( $(date +%s) - start ))
    bounded=0; [ "$elapsed" -lt 15 ] && bounded=1
    assert_true "T13 wedged stub returns bounded (${elapsed}s)" "$bounded"
    killed=0; { [ "$rc" = "124" ] || [ "$rc" = "137" ]; } && killed=1
    assert_true "T13 wedged stub surfaces the armor kill rc (got $rc)" "$killed"
    # The armor kill must NOT be silent — python never ran, so the wrapper
    # owns the ERR line ("block OWNS its error reporting" contract).
    assert_contains "T13 armor kill emits an ERR line on stderr" \
        "ERR resume-slot: python3 timed out/killed" "$err"
else
    echo "SKIP T13 (no GNU coreutils timeout on this runner)"
fi

# ---------------------------------------------------------------------------
# T14: null utilization on one window (HIMMEL-279) — fail loud (rc 2), NOT
#      silent 0%-coerce into ASAP. Covers the statusline-PR-#2 null path.
# ---------------------------------------------------------------------------
printf '{"five_hour":{"utilization":null,"resets_at":"%s"},"seven_day":{"utilization":30.0,"resets_at":"%s"}}' \
    "$(iso_in 18000)" "$(iso_in 604800)" > "$TMP/null-five.json"
t14_out="$TMP/t14-stdout"
err=$(bash "$SLOT" --cache "$TMP/null-five.json" --max-age 0 --emit epoch 2>&1 >"$t14_out"); rc=$?
assert_rc "T14 null five_hour util exits 2" 2 "$rc"
assert_contains "T14 surfaces null-utilization reason" "utilization is null" "$err"
# The die path must produce no stdout — no epoch/timestamp emitted on error.
t14_stdout=$(cat "$t14_out" 2>/dev/null || echo "")
t14_empty=0; [ -z "$t14_stdout" ] && t14_empty=1
assert_true "T14 no epoch/timestamp emitted on null-util die path (stdout is empty)" "$t14_empty"

# ---------------------------------------------------------------------------
# T15: null utilization on BOTH windows (HIMMEL-279) — fail loud (rc 2),
#      the 0%-coerce would have silently scheduled ASAP into a stalled cap.
# ---------------------------------------------------------------------------
printf '{"five_hour":{"utilization":null,"resets_at":"%s"},"seven_day":{"utilization":null,"resets_at":"%s"}}' \
    "$(iso_in 18000)" "$(iso_in 604800)" > "$TMP/null-both.json"
err=$(bash "$SLOT" --cache "$TMP/null-both.json" --max-age 0 --emit epoch 2>&1); rc=$?
assert_rc "T15 null both-windows util exits 2" 2 "$rc"
assert_contains "T15 surfaces null-utilization reason" "utilization is null" "$err"

# ---------------------------------------------------------------------------
# T16: EPOCH resets_at (HIMMEL-732 schema drift, missed here until HIMMEL-738)
#      — exhausted window with a raw epoch string like "1783760400" must pick
#      that reset, not die "resets_at missing/unparseable" (the live failure
#      that tore auto-arm-on-cap at seven_day=95%).
# ---------------------------------------------------------------------------
SEVEN_EPOCH=$((NOW + 200000))
mk_cache "$TMP/epoch.json" 10.0 "$((NOW + 9000))" 95.0 "$SEVEN_EPOCH"
out=$(bash "$SLOT" --cache "$TMP/epoch.json" --max-age 0 --emit all 2>&1); rc=$?
assert_rc "T16 epoch resets_at exits 0" 0 "$rc"
assert_contains "T16 waits for seven-day reset" "wait for seven-day reset" "$out"
ep=$(printf '%s' "$out" | cut -f1)
match=$(python3 -c 'import sys; print(1 if abs(int(sys.argv[1])-int(sys.argv[2]))<=1 else 0)' "$ep" "$SEVEN_EPOCH")
assert_true "T16 epoch == seven_day epoch reset" "$match"
# ...and a numeric (unquoted JSON number) resets_at is accepted too.
printf '{"five_hour":{"utilization":10.0,"resets_at":%s},"seven_day":{"utilization":95.0,"resets_at":%s}}' \
    "$((NOW + 9000))" "$SEVEN_EPOCH" > "$TMP/epochnum.json"
out=$(bash "$SLOT" --cache "$TMP/epochnum.json" --max-age 0 --emit reason 2>&1); rc=$?
assert_rc "T16b numeric resets_at exits 0" 0 "$rc"
assert_contains "T16b waits for seven-day reset" "wait for seven-day reset" "$out"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [ "$FAILED" -gt 0 ]; then echo "---"; echo "FAIL $FAILED case(s)"; exit 1; fi
echo "---"; echo "PASS all cases"; exit 0
