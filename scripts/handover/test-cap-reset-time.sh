#!/usr/bin/env bash
# Smoke test for scripts/handover/cap-reset-time.sh (HIMMEL-126).
#
# Exercises:
# - missing cache → rc=2
# - stale cache (rc=2) vs --max-age 0 bypass
# - missing window field → rc=3
# - --window five-hour | seven-day | invalid
# - --raw, --epoch, default (HH:MM)
# - unknown arg → rc=1
set -uo pipefail

CAP="$(cd "$(dirname "$0")" && pwd)/cap-reset-time.sh"
[ -x "$CAP" ] || chmod +x "$CAP"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_match() {
    local label="$1" pattern="$2" actual="$3"
    if [[ "$actual" =~ $pattern ]]; then
        echo "PASS $label"
    else
        echo "FAIL $label — output '$actual' did not match '$pattern'"
        FAILED=$((FAILED + 1))
    fi
}

FAILED=0

# Build a fresh fixture cache file.
FIXTURE="$TMP/cache.json"
cat > "$FIXTURE" <<'EOF'
{"five_hour":{"utilization":42.0,"resets_at":"2026-05-25T11:40:01.173252+00:00"},"seven_day":{"utilization":15.0,"resets_at":"2026-05-30T09:00:00+00:00"},"seven_day_oauth_apps":null}
EOF

# T1: default (HH:MM) — should print a valid 24h time
out=$(bash "$CAP" --cache "$FIXTURE" --max-age 0 2>&1)
rc=$?
assert_rc "T1 rc=0" 0 "$rc"
assert_match "T1 HH:MM shape" '^[0-2][0-9]:[0-5][0-9]$' "$out"

# T2: --raw outputs ISO 8601 verbatim
out=$(bash "$CAP" --cache "$FIXTURE" --max-age 0 --raw 2>&1)
assert_rc "T2 --raw rc=0" 0 "$?"
assert_match "T2 --raw is ISO 8601" '^2026-05-25T11:40:01\.173252\+00:00$' "$out"

# T3: --epoch outputs seconds-since-epoch
out=$(bash "$CAP" --cache "$FIXTURE" --max-age 0 --epoch 2>&1)
assert_rc "T3 --epoch rc=0" 0 "$?"
assert_match "T3 --epoch is int" '^[0-9]+$' "$out"

# T4: --window seven-day works
out=$(bash "$CAP" --cache "$FIXTURE" --max-age 0 --window seven-day 2>&1)
assert_rc "T4 --window seven-day rc=0" 0 "$?"
assert_match "T4 seven-day HH:MM shape" '^[0-2][0-9]:[0-5][0-9]$' "$out"

# T5: --window invalid → rc=1
bash "$CAP" --cache "$FIXTURE" --max-age 0 --window seven-year >/dev/null 2>&1
assert_rc "T5 invalid window rc=1" 1 "$?"

# T6: missing cache → rc=2
bash "$CAP" --cache "$TMP/does-not-exist.json" --max-age 0 >/dev/null 2>&1
assert_rc "T6 missing cache rc=2" 2 "$?"

# T7: stale cache (default --max-age 300, fixture mtime in distant past)
# Force the fixture to be 1 hour old.
touch -d "1 hour ago" "$FIXTURE" 2>/dev/null \
    || touch -t "$(date -v -1H +%Y%m%d%H%M.%S 2>/dev/null)" "$FIXTURE" 2>/dev/null \
    || true  # if neither GNU nor BSD touch flag works, skip the stale check (test platform doesn't support backdating)
bash "$CAP" --cache "$FIXTURE" >/dev/null 2>&1
assert_rc "T7 stale cache rc=2" 2 "$?"

# T8: --max-age 0 bypasses staleness — should succeed even with old mtime
bash "$CAP" --cache "$FIXTURE" --max-age 0 >/dev/null 2>&1
assert_rc "T8 --max-age 0 bypasses staleness" 0 "$?"

# T9: missing window field → rc=3
NULL_FIXTURE="$TMP/cache-null.json"
cat > "$NULL_FIXTURE" <<'EOF'
{"five_hour":{"utilization":0.0,"resets_at":null},"seven_day":{"utilization":0.0,"resets_at":null}}
EOF
bash "$CAP" --cache "$NULL_FIXTURE" --max-age 0 >/dev/null 2>&1
assert_rc "T9 null resets_at rc=3" 3 "$?"

# T10: unknown arg → rc=1
bash "$CAP" --bogus-flag >/dev/null 2>&1
assert_rc "T10 unknown arg rc=1" 1 "$?"

# T11: --help → rc=0
bash "$CAP" --help >/dev/null 2>&1
assert_rc "T11 --help rc=0" 0 "$?"

# T12: --window with underscore form works too
bash "$CAP" --cache "$FIXTURE" --max-age 0 --window five_hour >/dev/null 2>&1
assert_rc "T12 underscore window form rc=0" 0 "$?"

# T13: wedged python3 stub (HIMMEL-249) — epoch conversion must fail
#      BOUNDED with the script's own ERR + rc=3, never hang.
if timeout --version 2>/dev/null | grep -qi coreutils; then
    mkdir -p "$TMP/wedged-bin"
    cat > "$TMP/wedged-bin/python3" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep 30
EOF
    chmod +x "$TMP/wedged-bin/python3"
    start=$(date +%s)
    out=$(PATH="$TMP/wedged-bin:$PATH" PY_ARMOR_TIMEOUT=1 PY_ARMOR_KILL_AFTER=1 \
        bash "$CAP" --cache "$FIXTURE" --max-age 0 2>&1)
    rc=$?
    elapsed=$(( $(date +%s) - start ))
    assert_rc "T13 wedged stub fails with rc=3" 3 "$rc"
    assert_match "T13 wedged stub surfaces a clean ERR line" 'ERR cap-reset-time:' "$out"
    if [ "$elapsed" -lt 15 ]; then
        echo "PASS T13 bounded (${elapsed}s)"
    else
        echo "FAIL T13 bounded — took ${elapsed}s"
        FAILED=$((FAILED + 1))
    fi
else
    echo "SKIP T13 (no GNU coreutils timeout on this runner)"
fi

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
