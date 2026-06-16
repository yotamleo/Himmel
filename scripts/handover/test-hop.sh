#!/usr/bin/env bash
# Smoke test for scripts/handover/hop.sh (HIMMEL-130).
#
# Covers the snapshot-writing path + dry-run output shape. Does NOT
# exercise the live arm-resume call (--schedule) — that's covered by
# arm-resume's own integration test + manual verification at PR time.
set -uo pipefail

HOP="$(cd "$(dirname "$0")" && pwd)/hop.sh"
[ -x "$HOP" ] || chmod +x "$HOP"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/handovers/yotam"

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label — output missing: $needle"; FAILED=$((FAILED + 1)) ;;
    esac
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL $label — output unexpectedly contains: $needle"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS $label" ;;
    esac
}

FAILED=0

# T1: --print --dry-run with a message, custom handover root
out=$(bash "$HOP" --handover-root "$TMP/handovers/yotam" --message "test message" --print --dry-run 2>&1)
rc=$?
assert_rc "T1 print dry-run rc=0" 0 "$rc"
assert_contains "T1 mentions snapshot path" "$TMP/handovers/yotam/context-hop-" "$out"
assert_contains "T1 prints operator command" "claude \"load" "$out"
assert_contains "T1 embeds message in snapshot body" "test message" "$out"

# T2: --schedule (default) --dry-run — should mention arm-resume.sh
out=$(bash "$HOP" --handover-root "$TMP/handovers/yotam" --message "test" --dry-run 2>&1)
rc=$?
assert_rc "T2 schedule dry-run rc=0" 0 "$rc"
assert_contains "T2 mentions arm-resume.sh" "arm-resume.sh" "$out"

# T3: --delay 0 → usage error (out of [1, 60])
bash "$HOP" --handover-root "$TMP/handovers/yotam" --message "test" --delay 0 --dry-run >/dev/null 2>&1
rc=$?
assert_rc "T3 delay=0 usage error" 1 "$rc"

# T4: --delay 999 → usage error
bash "$HOP" --handover-root "$TMP/handovers/yotam" --message "test" --delay 999 --dry-run >/dev/null 2>&1
rc=$?
assert_rc "T4 delay=999 usage error" 1 "$rc"

# T5: --delay non-integer → usage error
bash "$HOP" --handover-root "$TMP/handovers/yotam" --message "test" --delay abc --dry-run >/dev/null 2>&1
rc=$?
assert_rc "T5 delay=abc usage error" 1 "$rc"

# T6: missing handover root → env-unusable error
bash "$HOP" --handover-root "$TMP/does-not-exist" --dry-run >/dev/null 2>&1
rc=$?
assert_rc "T6 missing handover root rc=2" 2 "$rc"

# T7: unknown arg → usage error
bash "$HOP" --bogus-flag >/dev/null 2>&1
rc=$?
assert_rc "T7 unknown arg rc=1" 1 "$rc"

# T8: live write — --print mode actually creates the snapshot file
before=$(find "$TMP/handovers/yotam" -name "context-hop-*.md" 2>/dev/null | wc -l)
bash "$HOP" --handover-root "$TMP/handovers/yotam" --message "live write test" --print >/dev/null 2>&1
rc=$?
assert_rc "T8 live --print rc=0" 0 "$rc"
after=$(find "$TMP/handovers/yotam" -name "context-hop-*.md" 2>/dev/null | wc -l)
if [ "$after" -eq $((before + 1)) ]; then
    echo "PASS T8 snapshot file created"
else
    echo "FAIL T8 expected $((before + 1)) snapshots, found $after"
    FAILED=$((FAILED + 1))
fi

# T9: snapshot contains expected sections
snapshot=$(find "$TMP/handovers/yotam" -name "context-hop-*.md" | head -1)
[ -f "$snapshot" ] && body=$(cat "$snapshot") || body=""
assert_contains "T9 snapshot has frontmatter" "session_kind: context-hop snapshot" "$body"
assert_contains "T9 snapshot has operator message section" "Operator message" "$body"
assert_contains "T9 snapshot embeds the live message" "live write test" "$body"
assert_contains "T9 snapshot has cold-start prompt" "Cold-start context-hop" "$body"

# T10: --help exits 0
bash "$HOP" --help >/dev/null 2>&1
rc=$?
assert_rc "T10 --help rc=0" 0 "$rc"

# T11 (HIMMEL-130 fix): schedule dry-run passes --cwd <origin> to arm-resume
out=$(bash "$HOP" --handover-root "$TMP/handovers/yotam" --message "cwd-test" --dry-run 2>&1)
arm_line=$(printf '%s\n' "$out" | grep -E '^DRY hop: would invoke' | head -1)
assert_contains "T11 dry-run passes --cwd to arm-resume" "--cwd '" "$arm_line"

# T12 (HIMMEL-130 fix): snapshot body records the origin repo line
out=$(bash "$HOP" --handover-root "$TMP/handovers/yotam" --message "origin-test" --dry-run 2>&1)
assert_contains "T12 snapshot has 'Origin repo (relaunch cwd)' line" "Origin repo (relaunch cwd)" "$out"

# T13 (HIMMEL-130 fix): dry-run WITHOUT --force does NOT include --force in arm-resume preview
out=$(bash "$HOP" --handover-root "$TMP/handovers/yotam" --message "no-force-test" --dry-run 2>&1)
arm_line=$(printf '%s\n' "$out" | grep -E '^DRY hop: would invoke' | head -1)
assert_not_contains "T13 dry-run without --force omits --force flag" " --force" "$arm_line"

# T14 (HIMMEL-130 fix): dry-run WITH --force DOES include --force in arm-resume preview
out=$(bash "$HOP" --handover-root "$TMP/handovers/yotam" --message "force-test" --force --dry-run 2>&1)
arm_line=$(printf '%s\n' "$out" | grep -E '^DRY hop: would invoke' | head -1)
assert_contains "T14 dry-run with --force includes --force flag" " --force" "$arm_line"

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
