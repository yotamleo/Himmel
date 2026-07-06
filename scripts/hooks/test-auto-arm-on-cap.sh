#!/usr/bin/env bash
# Smoke tests for scripts/hooks/auto-arm-on-cap.sh (HIMMEL-220).
#
# Stubs arm-resume.sh via AUTO_ARM_BIN and the usage cache via
# AUTO_ARM_CACHE; never touches the real scheduler or the real cache.
set -u -o pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/auto-arm-on-cap.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Isolate the quota-gauge ledger so threshold-trip tests never pollute the
# operator's real ~/.himmel/quota-gauge.jsonl (HIMMEL-687).
export HIMMEL_QUOTA_GAUGE_LEDGER="$TMP/quota-gauge.jsonl"

# Leak guard (HIMMEL-687): the real default ledger must be byte-identical
# after the suite -- proves the override above actually isolates writes.
REAL_LEDGER="${HOME:-}/.himmel/quota-gauge.jsonl"
if [ -f "$REAL_LEDGER" ]; then REAL_LEDGER_BEFORE="$(wc -c < "$REAL_LEDGER" | tr -d ' ')"; else REAL_LEDGER_BEFORE="ABSENT"; fi

pass=0
fail=0

assert_rc() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"
        pass=$((pass+1))
    else
        echo "  FAIL  $desc (expected rc=$expected, got rc=$actual)"
        fail=$((fail+1))
    fi
}

assert_file() {
    local desc="$1" mode="$2" path="$3"   # mode: present|absent
    local ok=0
    case "$mode" in
        present) [ -e "$path" ] && ok=1 ;;
        absent)  [ ! -e "$path" ] && ok=1 ;;
    esac
    if [ "$ok" = "1" ]; then
        echo "  PASS  $desc"
        pass=$((pass+1))
    else
        echo "  FAIL  $desc ($mode expected: $path)"
        fail=$((fail+1))
    fi
}

assert_grep() {
    local desc="$1" pattern="$2" file="$3"
    if [ -f "$file" ] && grep -q -- "$pattern" "$file"; then
        echo "  PASS  $desc"
        pass=$((pass+1))
    else
        echo "  FAIL  $desc (pattern '$pattern' not in $file)"
        fail=$((fail+1))
    fi
}

count_glob() {  # $1 = dir, $2 = name pattern
    find "$1" -maxdepth 1 -name "$2" 2>/dev/null | wc -l | tr -d ' '
}

# Shared stub arm.
ARM_STUB="$TMP/arm-stub.sh"
ARM_LOG="$TMP/arm-calls.log"
cat > "$ARM_STUB" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${ARM_LOG_PATH}"
exit "${ARM_STUB_RC:-0}"
EOF
chmod +x "$ARM_STUB"

write_cache() {
    # $1 = path, $2 = five_hour util, $3 = seven_day util, $4 = five_hour resets_at (optional)
    local resets="${4:-2026-06-10T13:30:00+00:00}"
    cat > "$1" <<EOF
{"five_hour":{"utilization":$2,"resets_at":"$resets"},"seven_day":{"utilization":$3,"resets_at":"2026-06-13T09:00:00+00:00"}}
EOF
}

HANDOVER_TEST_DIR="$TMP/handovers"
mkdir -p "$HANDOVER_TEST_DIR"
STDERR_LOG="$TMP/stderr.log"

run_hook() {
    # $1 = state dir, $2 = cache path; extra env via exported vars
    AUTO_ARM_STATE_DIR="$1" AUTO_ARM_CACHE="$2" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" \
    CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
}

echo "Test 1: kill switch — AUTO_ARM_DISABLE=1 is a no-op"
S="$TMP/s1"; mkdir -p "$S"
C="$TMP/c1.json"; write_cache "$C" 99 99
AUTO_ARM_DISABLE=1 AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" HANDOVER_DIR="$HANDOVER_TEST_DIR" \
    bash "$HOOK" </dev/null >/dev/null 2>&1
assert_rc "disabled hook exits 0" 0 $?
assert_file "disabled hook touches no throttle marker" absent "$S/auto-arm-last-check"

echo "Test 2: below threshold — no arm, throttle marker touched"
S="$TMP/s2"; mkdir -p "$S"
C="$TMP/c2.json"; write_cache "$C" 30 14
run_hook "$S" "$C"
assert_rc "below-threshold exits 0" 0 $?
assert_file "throttle marker written" present "$S/auto-arm-last-check"
assert_file "no arm call logged" absent "$ARM_LOG"

echo "Test 3: throttle — fresh last-check short-circuits even above threshold"
S="$TMP/s3"; mkdir -p "$S"
touch "$S/auto-arm-last-check"
C="$TMP/c3.json"; write_cache "$C" 95 14
run_hook "$S" "$C"
assert_rc "throttled run exits 0" 0 $?
assert_file "no arm call logged (throttled)" absent "$ARM_LOG"

echo "Test 4: above threshold — snapshot written, arm called, blocks once with instructions"
S="$TMP/s4"; mkdir -p "$S"
C="$TMP/c4.json"; write_cache "$C" 95 14
run_hook "$S" "$C"
assert_rc "tripped run exits 2 (one-shot block)" 2 $?
assert_file "arm stub invoked" present "$ARM_LOG"
assert_grep "arm invoked with --time smart" "--time smart" "$ARM_LOG"
assert_grep "arm invoked with --handover" "--handover" "$ARM_LOG"
# The --handover argument must point at a real file.
handover_arg=$(sed -E 's/.*--handover ([^ ]+).*/\1/' "$ARM_LOG" | head -1)
assert_file "snapshot passed to arm exists" present "$handover_arg"
snap_count=$(count_glob "$HANDOVER_TEST_DIR" 'auto-arm-status-*.md')
if [ "$snap_count" = "1" ]; then
    echo "  PASS  exactly one status snapshot in handover root"
    pass=$((pass+1))
else
    echo "  FAIL  exactly one status snapshot in handover root (got $snap_count)"
    fail=$((fail+1))
fi
assert_grep "snapshot has handover frontmatter" "type: handover" "$handover_arg"
assert_grep "snapshot names the utilization" "utilization at 95%" "$handover_arg"
assert_grep "block message says ACTION REQUIRED" "ACTION REQUIRED" "$STDERR_LOG"
assert_grep "block message says RESUME ARMED" "RESUME ARMED" "$STDERR_LOG"
fired=$(count_glob "$S" 'auto-arm-fired-*')
if [ "$fired" = "1" ]; then
    echo "  PASS  fired marker written"
    pass=$((pass+1))
else
    echo "  FAIL  fired marker written (got $fired)"
    fail=$((fail+1))
fi

echo "Test 5: one-shot — second run in same cap window is a quiet pass"
rm -f "$S/auto-arm-last-check"   # defeat the throttle, keep the fired marker
rm -f "$ARM_LOG"
run_hook "$S" "$C"
assert_rc "post-fire run exits 0" 0 $?
assert_file "no second arm call" absent "$ARM_LOG"

echo "Test 5b: NEW cap window (resets_at changed) re-fires"
rm -f "$S/auto-arm-last-check"
C5="$TMP/c5.json"; write_cache "$C5" 95 14 "2026-06-10T18:30:00+00:00"
run_hook "$S" "$C5"
assert_rc "new-window run exits 2 again" 2 $?
assert_file "second arm call logged" present "$ARM_LOG"
fired=$(count_glob "$S" 'auto-arm-fired-*')
if [ "$fired" = "2" ]; then
    echo "  PASS  distinct fired marker per cap window"
    pass=$((pass+1))
else
    echo "  FAIL  distinct fired marker per cap window (got $fired)"
    fail=$((fail+1))
fi

echo "Test 6: stale cache — quiet no-op on the FIRST observation (below escalation count)"
S="$TMP/s6"; mkdir -p "$S"
rm -f "$ARM_LOG"
C="$TMP/c6.json"; write_cache "$C" 95 14
if touch -d '@1' "$C" 2>/dev/null; then
    run_hook "$S" "$C"
    assert_rc "stale-cache run exits 0" 0 $?
    assert_file "no arm call on stale cache" absent "$ARM_LOG"
else
    echo "  SKIP  touch -d unsupported on this platform"
fi

echo "Test 7: arm failure (rc=4) — exit 1 (visible, non-blocking), no fired marker, stable snapshot"
S="$TMP/s7"; mkdir -p "$S"
H7="$TMP/handovers7"; mkdir -p "$H7"
C="$TMP/c7.json"; write_cache "$C" 95 14
rm -f "$ARM_LOG"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" ARM_STUB_RC=4 \
    HANDOVER_DIR="$H7" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "arm-failed run exits 1 (surfaced, non-blocking)" 1 $?
assert_grep "malfunction surfaced on stderr" "MALFUNCTION" "$STDERR_LOG"
fired=$(count_glob "$S" 'auto-arm-fired-*')
if [ "$fired" = "0" ]; then
    echo "  PASS  no fired marker on arm failure (retry next interval)"
    pass=$((pass+1))
else
    echo "  FAIL  no fired marker on arm failure (got $fired)"
    fail=$((fail+1))
fi

echo "Test 7b: repeated arm failure — NO snapshot spam (stable name), escalates to exit 2 on 3rd"
rm -f "$S/auto-arm-last-check"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" ARM_STUB_RC=4 \
    HANDOVER_DIR="$H7" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "2nd consecutive failure still exits 1" 1 $?
rm -f "$S/auto-arm-last-check"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" ARM_STUB_RC=4 \
    HANDOVER_DIR="$H7" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "3rd consecutive failure escalates to exit 2" 2 $?
assert_grep "escalation says COULD NOT ARM" "COULD NOT ARM" "$STDERR_LOG"
snap_count=$(count_glob "$H7" 'auto-arm-status-*.md')
if [ "$snap_count" = "1" ]; then
    echo "  PASS  retries overwrite ONE snapshot (no per-interval spam)"
    pass=$((pass+1))
else
    echo "  FAIL  retries overwrite ONE snapshot (got $snap_count)"
    fail=$((fail+1))
fi
fired=$(count_glob "$S" 'auto-arm-fired-*')
if [ "$fired" = "1" ]; then
    echo "  PASS  escalation sets the fired marker (one-shot honored)"
    pass=$((pass+1))
else
    echo "  FAIL  escalation sets the fired marker (got $fired)"
    fail=$((fail+1))
fi

echo "Test 8: arm dedup (rc=3, already armed) — fired marker + one-shot block + failcount reset"
S="$TMP/s8"; mkdir -p "$S"
C="$TMP/c8.json"; write_cache "$C" 95 14
rm -f "$ARM_LOG"
# Seed a stale failcount for this exact window key — success must clear it.
printf '2' > "$S/auto-arm-failcount-five_hour-2026-06-10T13-30-00-00-00"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" ARM_STUB_RC=3 \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "already-armed run exits 2 (still tells the model)" 2 $?
assert_grep "dedup message says ALREADY armed" "ALREADY armed" "$STDERR_LOG"
fired=$(count_glob "$S" 'auto-arm-fired-*')
if [ "$fired" = "1" ]; then
    echo "  PASS  fired marker written on dedup"
    pass=$((pass+1))
else
    echo "  FAIL  fired marker written on dedup (got $fired)"
    fail=$((fail+1))
fi
fc=$(count_glob "$S" 'auto-arm-failcount-*')
if [ "$fc" = "0" ]; then
    echo "  PASS  success clears the seeded failcount"
    pass=$((pass+1))
else
    echo "  FAIL  success clears the seeded failcount (got $fc)"
    fail=$((fail+1))
fi

echo "Test 9: missing cache — quiet no-op"
S="$TMP/s9"; mkdir -p "$S"
rm -f "$ARM_LOG"
run_hook "$S" "$TMP/does-not-exist.json"
assert_rc "missing-cache run exits 0" 0 $?
assert_file "no arm call on missing cache" absent "$ARM_LOG"

echo "Test 10: unparseable cache — quiet no-op"
S="$TMP/s10"; mkdir -p "$S"
C="$TMP/c10.json"; echo "not json {" > "$C"
run_hook "$S" "$C"
assert_rc "unparseable-cache run exits 0" 0 $?
assert_file "no arm call on unparseable cache" absent "$ARM_LOG"

echo "Test 11: schema drift — cache with NO parseable utilization is a quiet no-op (not 0%)"
S="$TMP/s11"; mkdir -p "$S"
C="$TMP/c11.json"
echo '{"five_hour":{"percent":99,"resets_at":"2026-06-10T13:30:00+00:00"},"seven_day":{"percent":99}}' > "$C"
run_hook "$S" "$C"
assert_rc "schema-drift run exits 0 (unusable signal, not healthy)" 0 $?
assert_file "no arm call on schema drift" absent "$ARM_LOG"

echo "Test 12: seven_day as the binding window trips too"
S="$TMP/s12"; mkdir -p "$S"
C="$TMP/c12.json"; write_cache "$C" 30 95
run_hook "$S" "$C"
assert_rc "seven_day-bound run exits 2" 2 $?
assert_grep "block message names seven_day" "seven_day" "$STDERR_LOG"
rm -f "$ARM_LOG"

echo "Test 13: boundary — utilization exactly at threshold trips (>=)"
S="$TMP/s13"; mkdir -p "$S"
C="$TMP/c13.json"; write_cache "$C" 90 14
run_hook "$S" "$C"
assert_rc "util==threshold run exits 2" 2 $?
rm -f "$ARM_LOG"

echo "Test 14: handover root unresolvable — snapshot falls back to state dir, arm still proceeds"
S="$TMP/s14"; mkdir -p "$S"
C="$TMP/c14.json"; write_cache "$C" 95 14
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$TMP/no-such-root" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "fallback run still exits 2 (armed)" 2 $?
assert_file "arm still called" present "$ARM_LOG"
snap_count=$(count_glob "$S" 'auto-arm-status-*.md')
if [ "$snap_count" = "1" ]; then
    echo "  PASS  snapshot fell back to state dir"
    pass=$((pass+1))
else
    echo "  FAIL  snapshot fell back to state dir (got $snap_count)"
    fail=$((fail+1))
fi
rm -f "$ARM_LOG"

echo "Test 15: missing arm-resume binary — exit 1 (surfaced), snapshot still written"
S="$TMP/s15"; mkdir -p "$S"
C="$TMP/c15.json"; write_cache "$C" 95 14
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" \
    AUTO_ARM_BIN="$TMP/no-such-arm.sh" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "missing-arm run exits 1 (surfaced)" 1 $?
assert_grep "missing arm surfaced as MALFUNCTION" "MALFUNCTION" "$STDERR_LOG"

echo "Test 16: missing py-armor lib (hook-relative AND project-dir fallback) — MALFUNCTION exit 1"
LIBLESS="$TMP/libless"; mkdir -p "$LIBLESS/hooks"
cp "$HOOK" "$LIBLESS/hooks/"
S="$TMP/s16"; mkdir -p "$S"
C="$TMP/c16.json"; write_cache "$C" 95 14
rm -f "$ARM_LOG"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="$TMP/no-such-projdir" \
    bash "$LIBLESS/hooks/auto-arm-on-cap.sh" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "missing-lib run exits 1 (MALFUNCTION, non-blocking)" 1 $?
assert_grep "missing lib surfaced as MALFUNCTION" "MALFUNCTION: cannot source py-armor.sh" "$STDERR_LOG"
assert_file "no arm call with the armor lib missing" absent "$ARM_LOG"

echo "Test 16b: hook-relative lib missing but \$CLAUDE_PROJECT_DIR/scripts/lib fallback resolves — hook proceeds"
PROJ16="$TMP/proj16"; mkdir -p "$PROJ16/scripts/lib"
cp "$(dirname "$HOOK")/../lib/py-armor.sh" "$PROJ16/scripts/lib/"
S="$TMP/s16b"; mkdir -p "$S"
C="$TMP/c16b.json"; write_cache "$C" 30 14
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="$PROJ16" \
    bash "$LIBLESS/hooks/auto-arm-on-cap.sh" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "fallback-lib run exits 0 (below threshold, hook functional)" 0 $?
assert_file "throttle marker written (hook ran past the lib source)" present "$S/auto-arm-last-check"

# ─── HIMMEL-275: stale-cache escalation (wedged-statusline seam) ─────────
# Frozen cache file with an ancient mtime + live hook invocations. All
# guarded on touch -d support (same as Test 6).
if touch -d '@1' "$TMP/probe-touch" 2>/dev/null; then

echo "Test 17: wedged statusline — 3rd consecutive stale check safety-arms (utilization-independent)"
S="$TMP/s17"; mkdir -p "$S"
H17="$TMP/handovers17"; mkdir -p "$H17"
rm -f "$ARM_LOG"
# LOW utilization on purpose: escalation keys on cache AGE, not on the
# (untrusted) frozen percentages. Default resets_at (2026-06-10) is past
# -> the +5h fallback slot.
C="$TMP/c17.json"; write_cache "$C" 30 14
touch -d '@1' "$C"
run_hook "$S" "$C"
assert_rc "1st stale check exits 0 (counting, not arming)" 0 $?
assert_file "no arm on 1st stale check" absent "$ARM_LOG"
rm -f "$S/auto-arm-last-check"
run_hook "$S" "$C"
assert_rc "2nd stale check exits 0" 0 $?
assert_file "no arm on 2nd stale check" absent "$ARM_LOG"
rm -f "$S/auto-arm-last-check"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$H17" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "3rd stale check escalates to exit 2 (one-shot block)" 2 $?
assert_file "safety arm invoked" present "$ARM_LOG"
assert_grep "arm got an explicit HH:MM slot (NOT --time smart)" "--time [0-2][0-9]:[0-5][0-9]" "$ARM_LOG"
if grep -q -- "--time smart" "$ARM_LOG"; then
    echo "  FAIL  safety arm must not use --time smart (it re-reads the wedged cache)"
    fail=$((fail+1))
else
    echo "  PASS  safety arm does not use --time smart"
    pass=$((pass+1))
fi
assert_grep "WARN names the wedge" "STATUSLINE WEDGED" "$STDERR_LOG"
assert_grep "WARN demands a handover" "ACTION REQUIRED" "$STDERR_LOG"
assert_grep "past resets_at falls back to now+5h" "fallback" "$STDERR_LOG"
snap_count=$(count_glob "$H17" 'auto-arm-status-stale-*.md')
if [ "$snap_count" = "1" ]; then
    echo "  PASS  safety snapshot written to handover root"
    pass=$((pass+1))
else
    echo "  FAIL  safety snapshot written to handover root (got $snap_count)"
    fail=$((fail+1))
fi
stale_markers=$(count_glob "$S" 'auto-arm-stale-escalated-*')
if [ "$stale_markers" = "1" ]; then
    echo "  PASS  escalated marker written (one-shot per wedge)"
    pass=$((pass+1))
else
    echo "  FAIL  escalated marker written (got $stale_markers)"
    fail=$((fail+1))
fi

echo "Test 17b: 4th check after escalation (no session_id) — no re-arm, dedup skip is VISIBLE (exit 1, shared-notice note)"
# No payload -> sid degrades to nosession -> every session shares ONE
# marker key, so the skip must not be a quiet exit 0 (exit-0 stderr is
# discarded by the harness; siblings would be suppressed invisibly).
rm -f "$S/auto-arm-last-check" "$ARM_LOG"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$H17" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "post-escalation nosession check exits 1 (visible dedup skip)" 1 $?
assert_file "no second safety arm" absent "$ARM_LOG"
assert_grep "skip names the shared wind-down notice" "sharing one wind-down notice" "$STDERR_LOG"
if grep -q "STATUSLINE WEDGED" "$STDERR_LOG"; then
    echo "  FAIL  exit-2 block text repeated on a post-escalation check"
    fail=$((fail+1))
else
    echo "  PASS  exit-2 block text not repeated on a post-escalation check"
    pass=$((pass+1))
fi

echo "Test 18: stale resets_at still in the FUTURE — safety arm targets that slot"
S="$TMP/s18"; mkdir -p "$S"
rm -f "$ARM_LOG"
future_iso=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%S+00:00"))')
expected_hhmm=$(python3 -c 'import datetime,sys; print(datetime.datetime.fromisoformat(sys.argv[1]).astimezone().strftime("%H:%M"))' "$future_iso")
C="$TMP/c18.json"; write_cache "$C" 30 14 "$future_iso"
touch -d '@1' "$C"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" AUTO_ARM_STALE_MIN_CHECKS=1 \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "future-resets_at escalation exits 2" 2 $?
assert_grep "arm targets the stale resets_at slot" "--time $expected_hhmm" "$ARM_LOG"
assert_grep "WARN names resets_at as the slot source" "resets_at" "$STDERR_LOG"

echo "Test 19: safety arm dedup (rc=3) — still a one-shot block, marker written"
S="$TMP/s19"; mkdir -p "$S"
rm -f "$ARM_LOG"
C="$TMP/c19.json"; write_cache "$C" 30 14
touch -d '@1' "$C"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" AUTO_ARM_STALE_MIN_CHECKS=1 \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" ARM_STUB_RC=3 \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "already-armed safety escalation exits 2" 2 $?
assert_grep "dedup message says ALREADY armed" "ALREADY armed" "$STDERR_LOG"
stale_markers=$(count_glob "$S" 'auto-arm-stale-escalated-*')
if [ "$stale_markers" = "1" ]; then
    echo "  PASS  escalated marker written on dedup"
    pass=$((pass+1))
else
    echo "  FAIL  escalated marker written on dedup (got $stale_markers)"
    fail=$((fail+1))
fi

echo "Test 20: safety arm failure (rc=4) — exit 1 surfaced, NO marker, retries and arms next check"
S="$TMP/s20"; mkdir -p "$S"
rm -f "$ARM_LOG"
C="$TMP/c20.json"; write_cache "$C" 30 14
touch -d '@1' "$C"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" AUTO_ARM_STALE_MIN_CHECKS=1 \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" ARM_STUB_RC=4 \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "failed safety arm exits 1 (surfaced, non-blocking)" 1 $?
assert_grep "failure surfaced as MALFUNCTION" "MALFUNCTION" "$STDERR_LOG"
stale_markers=$(count_glob "$S" 'auto-arm-stale-escalated-*')
if [ "$stale_markers" = "0" ]; then
    echo "  PASS  no escalated marker on arm failure (retry next interval)"
    pass=$((pass+1))
else
    echo "  FAIL  no escalated marker on arm failure (got $stale_markers)"
    fail=$((fail+1))
fi
rm -f "$S/auto-arm-last-check"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" AUTO_ARM_STALE_MIN_CHECKS=1 \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "retry with a working arm escalates to exit 2" 2 $?

echo "Test 21: a fresh cache breaks the stale streak (counter resets)"
S="$TMP/s21"; mkdir -p "$S"
rm -f "$ARM_LOG"
CS="$TMP/c21-stale.json"; write_cache "$CS" 30 14
touch -d '@1' "$CS"
CF="$TMP/c21-fresh.json"; write_cache "$CF" 30 14
run_hook "$S" "$CS"; rm -f "$S/auto-arm-last-check"
run_hook "$S" "$CS"; rm -f "$S/auto-arm-last-check"
assert_file "streak counted across 2 stale checks" present "$S/auto-arm-stale-count"
run_hook "$S" "$CF"; rm -f "$S/auto-arm-last-check"
assert_file "fresh cache clears the stale counter" absent "$S/auto-arm-stale-count"
run_hook "$S" "$CS"; rm -f "$S/auto-arm-last-check"
run_hook "$S" "$CS"
assert_rc "2 stale checks after a fresh one stay below the count bound" 0 $?
assert_file "no arm after the streak was broken" absent "$ARM_LOG"

echo "Test 22: per-SESSION one-shot — a second session under the SAME wedge gets its own block"
S="$TMP/s22"; mkdir -p "$S"
rm -f "$ARM_LOG"
C="$TMP/c22.json"; write_cache "$C" 30 14
touch -d '@1' "$C"
run_hook_sid() {  # $1 = state dir, $2 = cache, $3 = session id, $4 = arm stub rc (optional)
    printf '{"session_id":"%s"}\n' "$3" | \
    AUTO_ARM_STATE_DIR="$1" AUTO_ARM_CACHE="$2" AUTO_ARM_STALE_MIN_CHECKS=1 \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" ARM_STUB_RC="${4:-0}" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" >/dev/null 2>"$STDERR_LOG"
}
run_hook_sid "$S" "$C" "session-alpha-0001"
assert_rc "session A escalates (exit 2)" 2 $?
rm -f "$S/auto-arm-last-check"
run_hook_sid "$S" "$C" "session-alpha-0001"
assert_rc "session A re-check — one-shot held (exit 0)" 0 $?
rm -f "$S/auto-arm-last-check" "$ARM_LOG"
# Session B under the same frozen mtime: must get its OWN block; the arm
# itself dedups at the scheduler (rc=3 = already armed counts as success).
run_hook_sid "$S" "$C" "session-beta-0002" 3
assert_rc "session B under the same wedge blocks too (exit 2)" 2 $?
assert_grep "session B told a resume is ALREADY armed (scheduler dedup)" "ALREADY armed" "$STDERR_LOG"
stale_markers=$(count_glob "$S" 'auto-arm-stale-escalated-*')
if [ "$stale_markers" = "2" ]; then
    echo "  PASS  distinct escalated marker per session"
    pass=$((pass+1))
else
    echo "  FAIL  distinct escalated marker per session (got $stale_markers)"
    fail=$((fail+1))
fi
rm -f "$S/auto-arm-last-check"
run_hook_sid "$S" "$C" "session-beta-0002"
assert_rc "session B re-check — one-shot held (exit 0)" 0 $?

echo "Test 23: resets_at more than 24h out — slot must fall back to now+5h (HH:MM can only express today/tomorrow)"
S="$TMP/s23"; mkdir -p "$S"
rm -f "$ARM_LOG"
far_iso=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=30)).strftime("%Y-%m-%dT%H:%M:%S+00:00"))')
far_hhmm=$(python3 -c 'import datetime,sys; print(datetime.datetime.fromisoformat(sys.argv[1]).astimezone().strftime("%H:%M"))' "$far_iso")
C="$TMP/c23.json"; write_cache "$C" 30 14 "$far_iso"
touch -d '@1' "$C"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" AUTO_ARM_STALE_MIN_CHECKS=1 \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc ">24h-resets_at escalation exits 2" 2 $?
assert_grep "slot source is the now+5h fallback" "fallback" "$STDERR_LOG"
if grep -q -- "--time $far_hhmm" "$ARM_LOG"; then
    echo "  FAIL  arm targeted the >24h resets_at HH:MM (would arm the wrong day)"
    fail=$((fail+1))
else
    echo "  PASS  arm did not target the >24h resets_at HH:MM"
    pass=$((pass+1))
fi

echo "Test 24: burst of tool calls WITHOUT clearing the throttle — counter stays at 1, no escalation"
S="$TMP/s24"; mkdir -p "$S"
rm -f "$ARM_LOG"
C="$TMP/c24.json"; write_cache "$C" 30 14
touch -d '@1' "$C"
run_hook "$S" "$C"   # 1st REAL check: counter -> 1, throttle marker written
run_hook "$S" "$C"   # throttled
run_hook "$S" "$C"   # throttled
run_hook "$S" "$C"   # throttled
assert_rc "burst run exits 0 (throttled)" 0 $?
count_val=$(cat "$S/auto-arm-stale-count" 2>/dev/null || echo missing)
if [ "$count_val" = "1" ]; then
    echo "  PASS  throttled burst does not inflate the stale counter (stays 1)"
    pass=$((pass+1))
else
    echo "  FAIL  throttled burst does not inflate the stale counter (got '$count_val')"
    fail=$((fail+1))
fi
assert_file "no arm from a same-interval burst" absent "$ARM_LOG"

echo "Test 25: unpersistable stale counter — loud WARN + immediate escalation (no silent stuck-at-1)"
S="$TMP/s25"; mkdir -p "$S"
rm -f "$ARM_LOG"
C="$TMP/c25.json"; write_cache "$C" 30 14
touch -d '@1' "$C"
mkdir -p "$S/auto-arm-stale-count"   # directory-as-file: the counter redirect fails portably (incl. Windows)
run_hook "$S" "$C"
assert_rc "counter-unpersistable run escalates immediately (exit 2)" 2 $?
assert_grep "WARN names the unpersistable counter" "cannot persist stale counter" "$STDERR_LOG"
assert_file "safety arm still invoked despite the dead counter" present "$ARM_LOG"

echo "Test 26: unpersistable one-shot marker — arm proceeds, block downgrades to exit 1 (never a block loop)"
S="$TMP/s26"; mkdir -p "$S"
rm -f "$ARM_LOG"
C="$TMP/c26.json"; write_cache "$C" 30 14
touch -d '@1' "$C"
# Collide with the deterministic marker path: mtime=1 + no payload -> sid "nosession".
mkdir -p "$S/auto-arm-stale-escalated-1-nosession"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" AUTO_ARM_STALE_MIN_CHECKS=1 \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "marker-unpersistable escalation exits 1 (visible, non-blocking)" 1 $?
assert_grep "warn says the marker is UNWRITABLE" "UNWRITABLE" "$STDERR_LOG"
assert_file "safety arm still invoked" present "$ARM_LOG"
if grep -q "fires once" "$STDERR_LOG"; then
    echo "  FAIL  message must not promise a one-shot it cannot keep"
    fail=$((fail+1))
else
    echo "  PASS  message does not promise a one-shot it cannot keep"
    pass=$((pass+1))
fi
rm -f "$S/auto-arm-last-check"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" AUTO_ARM_STALE_MIN_CHECKS=1 \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "next check repeats the visible warn (exit 1), never an exit-2 loop" 1 $?

echo "Test 27: sid temp file — per-process, deleted after the read, orphans swept by the hygiene glob"
S="$TMP/s27"; mkdir -p "$S"
rm -f "$ARM_LOG"
C="$TMP/c27.json"; write_cache "$C" 30 14
touch -d '@1' "$C"
# Orphan from a killed process (fixed pre-fix name AND a per-PID name),
# older than the 8-day sweep bound — the widened glob must catch both.
touch "$S/auto-arm-sid-out" "$S/auto-arm-sid-out.99999"
touch -d '@1' "$S/auto-arm-sid-out" "$S/auto-arm-sid-out.99999"
run_hook_sid "$S" "$C" "session-gamma-0003"
assert_rc "escalation run exits 2" 2 $?
assert_file "orphaned bare sid temp file swept" absent "$S/auto-arm-sid-out"
assert_file "orphaned per-PID sid temp file swept" absent "$S/auto-arm-sid-out.99999"
sid_left=$(count_glob "$S" 'auto-arm-sid-out*')
if [ "$sid_left" = "0" ]; then
    echo "  PASS  sid temp file deleted after the read (no residue in state dir)"
    pass=$((pass+1))
else
    echo "  FAIL  sid temp file deleted after the read (got $sid_left left)"
    fail=$((fail+1))
fi

# --- HIMMEL-690: stale-cache safety arm picks the binding bank -------------
# The stale slot must consider BOTH windows and target the binding (exhausted)
# bank's reset, not a hardcoded five_hour. A candidate is a window whose
# utilization >= threshold AND whose resets_at lands in (now+120s, now+24h].

echo "Test 42: stale cache -- seven_day util high + reset in range, five_hour low -> arm targets seven_day reset"
S="$TMP/s42"; mkdir -p "$S"
rm -f "$ARM_LOG"
seven_iso=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%S+00:00"))')
seven_hhmm=$(python3 -c 'import datetime,sys; print(datetime.datetime.fromisoformat(sys.argv[1]).astimezone().strftime("%H:%M"))' "$seven_iso")
C="$TMP/c42.json"
printf '{"five_hour":{"utilization":10,"resets_at":"2026-06-10T13:30:00+00:00"},"seven_day":{"utilization":95,"resets_at":"%s"}}' "$seven_iso" > "$C"
touch -d '@1' "$C"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" AUTO_ARM_STALE_MIN_CHECKS=1 \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "seven_day-binding stale escalation exits 2" 2 $?
assert_grep "arm targets the seven_day reset slot" "--time $seven_hhmm" "$ARM_LOG"
assert_grep "WARN names the seven_day resets_at source" "stale cache seven_day resets_at" "$STDERR_LOG"

echo "Test 43: both banks >= threshold + resets in range -> the LATER reset wins (time-based, not name-based)"
S="$TMP/s43"; mkdir -p "$S"
rm -f "$ARM_LOG"
# five_hour reset is the LATER one here -> it must win, proving the pick is by
# latest reset, not by window iteration order.
five_iso=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=6)).strftime("%Y-%m-%dT%H:%M:%S+00:00"))')
seven_iso=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%S+00:00"))')
five_hhmm=$(python3 -c 'import datetime,sys; print(datetime.datetime.fromisoformat(sys.argv[1]).astimezone().strftime("%H:%M"))' "$five_iso")
C="$TMP/c43.json"
printf '{"five_hour":{"utilization":95,"resets_at":"%s"},"seven_day":{"utilization":95,"resets_at":"%s"}}' "$five_iso" "$seven_iso" > "$C"
touch -d '@1' "$C"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" AUTO_ARM_STALE_MIN_CHECKS=1 \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "both-binding stale escalation exits 2" 2 $?
assert_grep "arm targets the LATER (five_hour) reset slot" "--time $five_hhmm" "$ARM_LOG"
assert_grep "WARN names the five_hour resets_at source (later wins)" "stale cache five_hour resets_at" "$STDERR_LOG"

echo "Test 44: seven_day util high but reset >24h out, five_hour low -> today's fallback (now+5h)"
S="$TMP/s44"; mkdir -p "$S"
rm -f "$ARM_LOG"
far_iso=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=30)).strftime("%Y-%m-%dT%H:%M:%S+00:00"))')
far_hhmm=$(python3 -c 'import datetime,sys; print(datetime.datetime.fromisoformat(sys.argv[1]).astimezone().strftime("%H:%M"))' "$far_iso")
C="$TMP/c44.json"
printf '{"five_hour":{"utilization":10,"resets_at":"2026-06-10T13:30:00+00:00"},"seven_day":{"utilization":95,"resets_at":"%s"}}' "$far_iso" > "$C"
touch -d '@1' "$C"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" AUTO_ARM_STALE_MIN_CHECKS=1 \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "seven_day-reset-out-of-range stale escalation exits 2" 2 $?
assert_grep "slot source is the now+5h fallback (no valid candidate)" "fallback" "$STDERR_LOG"
if grep -q -- "--time $far_hhmm" "$ARM_LOG"; then
    echo "  FAIL  arm targeted the >24h seven_day reset (candidate filter broken)"
    fail=$((fail+1))
else
    echo "  PASS  arm did not target the out-of-range seven_day reset"
    pass=$((pass+1))
fi

echo "Test 45: corrupt seven_day utilization (leaked timestamp, HIMMEL-625) -> not a candidate; falls back"
S="$TMP/s45"; mkdir -p "$S"
rm -f "$ARM_LOG"
# seven_day utilization is a leaked epoch (~1.78e9): >= threshold numerically
# but garbage. Without the sanity ceiling the corrupt bank would be elected
# (its reset is in range, 2h out) and the safety arm dragged to it; with the
# ceiling there is NO candidate and the slot is the now+5h fallback.
seven_iso=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%S+00:00"))')
seven_hhmm=$(python3 -c 'import datetime,sys; print(datetime.datetime.fromisoformat(sys.argv[1]).astimezone().strftime("%H:%M"))' "$seven_iso")
C="$TMP/c45.json"
printf '{"five_hour":{"utilization":10,"resets_at":"2026-06-10T13:30:00+00:00"},"seven_day":{"utilization":1782696700,"resets_at":"%s"}}' "$seven_iso" > "$C"
touch -d '@1' "$C"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" AUTO_ARM_STALE_MIN_CHECKS=1 \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "corrupt-utilization stale escalation exits 2" 2 $?
assert_grep "slot source is the now+5h fallback (corrupt bank rejected)" "fallback" "$STDERR_LOG"
if grep -q -- "--time $seven_hhmm" "$ARM_LOG"; then
    echo "  FAIL  arm targeted the corrupt seven_day bank's reset (sanity ceiling missing)"
    fail=$((fail+1))
else
    echo "  PASS  arm did not target the corrupt seven_day bank's reset"
    pass=$((pass+1))
fi

echo "Test 46: five_hour binding, seven_day LOW util with a LATER in-range reset -> arm stays at five_hour (AC: a 5h trip never arms at the weekly reset)"
S="$TMP/s46"; mkdir -p "$S"
rm -f "$ARM_LOG"
# Mirror of Test 42 with utils swapped: seven_day is below threshold so it must
# be filtered out EVEN THOUGH its reset is later and in range — pins the
# threshold-filter-before-reset-pick order (the exact bug class HIMMEL-690 fixes).
five_iso=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%S+00:00"))')
seven_iso=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=6)).strftime("%Y-%m-%dT%H:%M:%S+00:00"))')
five_hhmm=$(python3 -c 'import datetime,sys; print(datetime.datetime.fromisoformat(sys.argv[1]).astimezone().strftime("%H:%M"))' "$five_iso")
seven_hhmm=$(python3 -c 'import datetime,sys; print(datetime.datetime.fromisoformat(sys.argv[1]).astimezone().strftime("%H:%M"))' "$seven_iso")
C="$TMP/c46.json"
printf '{"five_hour":{"utilization":95,"resets_at":"%s"},"seven_day":{"utilization":10,"resets_at":"%s"}}' "$five_iso" "$seven_iso" > "$C"
touch -d '@1' "$C"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" AUTO_ARM_STALE_MIN_CHECKS=1 \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "five_hour-binding stale escalation exits 2" 2 $?
assert_grep "arm targets the five_hour reset slot" "--time $five_hhmm" "$ARM_LOG"
assert_grep "WARN names the five_hour resets_at source" "stale cache five_hour resets_at" "$STDERR_LOG"
if grep -q -- "--time $seven_hhmm" "$ARM_LOG"; then
    echo "  FAIL  arm was pulled to the low-util seven_day reset (threshold filter broken)"
    fail=$((fail+1))
else
    echo "  PASS  arm was not pulled to the low-util seven_day reset"
    pass=$((pass+1))
fi

else
    echo "  SKIP  Tests 17-27 (touch -d unsupported on this platform)"
fi

# ─── threshold-trip: failcount unpersistable + mktemp fallback ───────────
# These tests (#422, #427) cover the threshold-trip code path, NOT the
# stale-cache path above. No touch -d needed — they use a fresh cache.

echo "Test 28: unpersistable counter — escalation message says 'single observation' not 'N consecutive times'"
S="$TMP/s28"; mkdir -p "$S"
H28="$TMP/handovers28"; mkdir -p "$H28"
C="$TMP/c28.json"; write_cache "$C" 95 14
# Pre-create failcount as a directory — printf > dir fails portably.
window_key_part="five_hour-2026-06-10T13-30-00-00-00"
mkdir -p "$S/auto-arm-failcount-${window_key_part}"  # directory, not file — write fails
rm -f "$ARM_LOG"
AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$C" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" ARM_STUB_RC=4 \
    HANDOVER_DIR="$H28" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG"
assert_rc "unpersistable counter escalates immediately (exit 2)" 2 $?
assert_grep "escalation message mentions 'single observation'" "single observation" "$STDERR_LOG"
if grep -q 'consecutive times' "$STDERR_LOG" && ! grep -q 'single observation' "$STDERR_LOG"; then
    echo "  FAIL  T28 message says 'consecutive times' without 'single observation' — misleading"
    fail=$((fail+1))
fi
rm -rf "$S/auto-arm-failcount-${window_key_part}"

echo "Test 29: both snapshot dirs unwritable — mktemp fallback; warn message contains 'will NOT auto-arm' on total failure"
# Compile-time check: verify the source contains the expected warn text.
assert_grep "T29a source contains 'will NOT auto-arm' in warn" "will NOT auto-arm" "$HOOK"
# Runtime: block both preferred dirs, let mktemp succeed; arm still proceeds.
S29="$TMP/s29"; mkdir -p "$S29"
H29="$TMP/handovers29-no-such-dir"
C="$TMP/c29.json"; write_cache "$C" 95 14
fired_key_29="five_hour-2026-06-10T13-30-00-00-00-nosession"
# Pre-create snapshot target as a directory — write_snapshot will fail.
mkdir -p "$S29/auto-arm-status-${fired_key_29}.md"
rm -f "$ARM_LOG"
AUTO_ARM_STATE_DIR="$S29" AUTO_ARM_CACHE="$C" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$H29" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" </dev/null >/dev/null 2>"$STDERR_LOG" || true
# mktemp in /tmp should succeed on all platforms — arm still called.
if [ -f "$ARM_LOG" ]; then
    echo "  PASS  T29 mktemp fallback — arm proceeded despite both preferred snapshot paths blocked"
    pass=$((pass+1))
else
    assert_grep "T29 total failure warns 'will NOT auto-arm'" "will NOT auto-arm" "$STDERR_LOG"
fi
rm -rf "$S29/auto-arm-status-${fired_key_29}.md"

# ─── HIMMEL-279: null utilization in the threshold-trip python block ─────
# Fresh cache, threshold check path (NOT the stale path above). These cover
# the statusline PR #2 null-field guard: key absent = schema drift (silent
# skip); key present but null = UNKNOWN (warn + skip that window); all null
# = MALFUNCTION exit 1.

echo "Test 30: null utilization on one window, other below threshold (HIMMEL-279) — warn + quiet no-op (below threshold)"
S="$TMP/s30"; mkdir -p "$S"
C="$TMP/c30.json"
printf '{"five_hour":{"utilization":null,"resets_at":"2026-06-10T13:30:00+00:00"},"seven_day":{"utilization":30,"resets_at":"2026-06-13T09:00:00+00:00"}}' > "$C"
rm -f "$ARM_LOG"
run_hook "$S" "$C"
assert_rc "null-one-below-threshold exits 0 (no arm)" 0 $?
assert_file "no arm call when below threshold despite one null" absent "$ARM_LOG"
# The warn about null must appear in stderr so the operator sees it.
if grep -q "null" "$STDERR_LOG" 2>/dev/null; then
    echo "  PASS  null-window warning surfaced on stderr"
    pass=$((pass+1))
else
    echo "  FAIL  null-window warning not surfaced on stderr"
    fail=$((fail+1))
fi

echo "Test 31: null utilization on one window, other above threshold (HIMMEL-279) — warn + still ARM"
S="$TMP/s31"; mkdir -p "$S"
C="$TMP/c31.json"
printf '{"five_hour":{"utilization":null,"resets_at":"2026-06-10T13:30:00+00:00"},"seven_day":{"utilization":95,"resets_at":"2026-06-13T09:00:00+00:00"}}' > "$C"
rm -f "$ARM_LOG"
run_hook "$S" "$C"
assert_rc "null-one-above-threshold still trips (exits 2)" 2 $?
assert_file "arm still called when one window above threshold" present "$ARM_LOG"
if grep -q "null" "$STDERR_LOG" 2>/dev/null; then
    echo "  PASS  null-window warning surfaced alongside trip"
    pass=$((pass+1))
else
    echo "  FAIL  null-window warning not surfaced alongside trip"
    fail=$((fail+1))
fi
rm -f "$ARM_LOG"

echo "Test 32: BOTH windows null (HIMMEL-279) — MALFUNCTION exit 1, NOT quiet no-op"
S="$TMP/s32"; mkdir -p "$S"
C="$TMP/c32.json"
printf '{"five_hour":{"utilization":null,"resets_at":"2026-06-10T13:30:00+00:00"},"seven_day":{"utilization":null,"resets_at":"2026-06-13T09:00:00+00:00"}}' > "$C"
rm -f "$ARM_LOG"
run_hook "$S" "$C"
assert_rc "both-null exits 1 (MALFUNCTION, not silent)" 1 $?
assert_file "no arm call on all-null signal" absent "$ARM_LOG"
assert_grep "MALFUNCTION surfaced for all-null cache" "MALFUNCTION" "$STDERR_LOG"

# ─── HIMMEL-625: out-of-range utilization (a leaked epoch timestamp) ─────
# Fresh cache, threshold-trip python path. The statusline writer leaked a
# Unix epoch (1782696700 ~ 1.78e9) into five_hour.utilization on 2026-06-29;
# the watchdog armed a spurious resume because 1.78e9 >= 90. An out-of-range
# numeric must be treated as UNKNOWN (like null), never as a cap.
LEAKED_TS=1782696700

echo "Test 33: leaked-timestamp utilization on five_hour, seven_day normal (the 2026-06-29 incident) — UNKNOWN, no spurious arm"
S="$TMP/s33"; mkdir -p "$S"
C="$TMP/c33.json"; write_cache "$C" "$LEAKED_TS" 47
rm -f "$ARM_LOG"
run_hook "$S" "$C"
assert_rc "out-of-range five_hour does not trip (exits 0)" 0 $?
assert_file "no spurious arm on a leaked-timestamp utilization" absent "$ARM_LOG"
assert_grep "out-of-range warning surfaced on stderr" "out of plausible range" "$STDERR_LOG"

echo "Test 34: out-of-range on five_hour but seven_day genuinely above threshold — still ARMs on the good window"
S="$TMP/s34"; mkdir -p "$S"
C="$TMP/c34.json"; write_cache "$C" "$LEAKED_TS" 95
rm -f "$ARM_LOG"
run_hook "$S" "$C"
assert_rc "real seven_day cap still trips despite garbage five_hour (exits 2)" 2 $?
assert_file "arm called on the genuinely-high window" present "$ARM_LOG"
assert_grep "block names seven_day as the binding window" "seven_day" "$STDERR_LOG"
rm -f "$ARM_LOG"

echo "Test 35: BOTH windows out-of-range — MALFUNCTION exit 1, NOT a spurious arm, NOT a silent no-op"
S="$TMP/s35"; mkdir -p "$S"
C="$TMP/c35.json"; write_cache "$C" "$LEAKED_TS" "$LEAKED_TS"
rm -f "$ARM_LOG"
run_hook "$S" "$C"
assert_rc "all-out-of-range exits 1 (MALFUNCTION, not silent)" 1 $?
assert_file "no arm call on an all-garbage cache" absent "$ARM_LOG"
assert_grep "MALFUNCTION surfaced for all-out-of-range cache" "MALFUNCTION" "$STDERR_LOG"

echo "Test 36: negative utilization is also out-of-range — treated as UNKNOWN"
S="$TMP/s36"; mkdir -p "$S"
C="$TMP/c36.json"; write_cache "$C" -5 30
rm -f "$ARM_LOG"
run_hook "$S" "$C"
assert_rc "negative five_hour does not trip (exits 0)" 0 $?
assert_file "no arm on a negative utilization" absent "$ARM_LOG"
assert_grep "negative value travels the out-of-range warn path" "out of plausible range" "$STDERR_LOG"

echo "Test 37: utilization exactly at SANITY_MAX (1000) is IN range — still a real cap, trips"
# Pins the inclusive ceiling: a future <= -> < or 1000 -> 100 drift breaks this.
S="$TMP/s37"; mkdir -p "$S"
C="$TMP/c37.json"; write_cache "$C" 1000 30
rm -f "$ARM_LOG"
run_hook "$S" "$C"
assert_rc "util==SANITY_MAX trips (exits 2)" 2 $?
assert_file "arm called at the inclusive ceiling" present "$ARM_LOG"
rm -f "$ARM_LOG"

echo "Test 38: utilization just over SANITY_MAX (1001) — out-of-range, treated as UNKNOWN"
S="$TMP/s38"; mkdir -p "$S"
C="$TMP/c38.json"; write_cache "$C" 1001 30
rm -f "$ARM_LOG"
run_hook "$S" "$C"
assert_rc "util just over the ceiling does not trip (exits 0)" 0 $?
assert_file "no arm just over the ceiling" absent "$ARM_LOG"
assert_grep "over-ceiling warning surfaced on stderr" "out of plausible range" "$STDERR_LOG"

echo "Test 39: a legitimate over-100 overage reading (150) stays valid — trips (design intent of SANITY_MAX>100)"
S="$TMP/s39"; mkdir -p "$S"
C="$TMP/c39.json"; write_cache "$C" 150 30
rm -f "$ARM_LOG"
run_hook "$S" "$C"
assert_rc "real over-100 overage still trips (exits 2)" 2 $?
assert_file "arm called on a 150% overage" present "$ARM_LOG"
rm -f "$ARM_LOG"

# --- HIMMEL-687: leak guard -- real ledger untouched by the suite -----------
echo "Test 40: quota-gauge ledger isolation -- real ~/.himmel/quota-gauge.jsonl untouched"
if [ -f "$REAL_LEDGER" ]; then REAL_LEDGER_AFTER="$(wc -c < "$REAL_LEDGER" | tr -d ' ')"; else REAL_LEDGER_AFTER="ABSENT"; fi
if [ "$REAL_LEDGER_BEFORE" = "$REAL_LEDGER_AFTER" ]; then
    echo "  PASS  real quota-gauge ledger untouched (no leak): $REAL_LEDGER_BEFORE"
    pass=$((pass+1))
else
    echo "  FAIL  real quota-gauge ledger LEAKED (before=$REAL_LEDGER_BEFORE after=$REAL_LEDGER_AFTER)"
    fail=$((fail+1))
fi

# --- HIMMEL-687: positive-write guard -- keeps Test 40 non-vacuous ----------
# quota_gauge_note_claude is fail-open/silent (auto-arm-on-cap.sh header): if the
# whole write path ever dies (sourcing fails, append silently errors) NO ledger
# is written -- neither real nor isolated -- and Test 40 would pass vacuously.
# Assert the isolated ledger actually accumulated writes so a dead write path
# fails loudly instead of masquerading as "no leak".
echo "Test 41: isolated ledger received writes -- leak-guard was actually exercised"
if [ -s "$HIMMEL_QUOTA_GAUGE_LEDGER" ]; then
    echo "  PASS  isolated ledger got writes: $(wc -c < "$HIMMEL_QUOTA_GAUGE_LEDGER" | tr -d ' ') bytes"
    pass=$((pass+1))
else
    echo "  FAIL  isolated ledger EMPTY -- write path never exercised (Test 40 vacuous)"
    fail=$((fail+1))
fi

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
