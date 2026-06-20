#!/usr/bin/env bash
# Smoke / invariant tests for scripts/telegram/auto-action.sh (HIMMEL-424 B2).
#
# auto-action.sh is the privileged half of the remote auto-action surface: the
# trusted bridge invokes it (argv array) to resolve a ticket|path to a resume
# handover and shell arm-resume.sh. These tests stub the arm command
# (AUTO_ACTION_ARM_CMD) so no real scheduler job is ever created, and use a
# fixture HANDOVER_DIR so resolution is deterministic.
set -uo pipefail

AA="$(cd "$(dirname "$0")" && pwd)/auto-action.sh"
[ -x "$AA" ] || chmod +x "$AA" 2>/dev/null || true

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then echo "PASS $label (rc=$actual)"
    else echo "FAIL $label — expected rc=$expected, got rc=$actual"; FAILED=$((FAILED + 1)); fi
}
assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in *"$needle"*) echo "PASS $label" ;; *) echo "FAIL $label — missing: $needle"; FAILED=$((FAILED + 1)) ;; esac
}
FAILED=0

# --- Fixtures -------------------------------------------------------------
export HANDOVER_DIR="$TMP/handovers"
mkdir -p "$HANDOVER_DIR/yotam/himmel/specs/design"

# A genuine resume handover (lowercase filename, type: handover frontmatter).
cat > "$HANDOVER_DIR/yotam/himmel/2026-06-20-himmel-777-resume.md" <<'EOF'
---
type: handover
ticket: HIMMEL-777
---
resume me
EOF

# A design doc under specs/ — must NOT be a resolution candidate.
cat > "$HANDOVER_DIR/yotam/himmel/specs/design/2026-06-20-himmel-888-design.md" <<'EOF'
# HIMMEL-888 design
not a resume target
EOF

# Two genuine handovers for the same ticket → ambiguous.
cat > "$HANDOVER_DIR/yotam/himmel/2026-06-19-himmel-999-a.md" <<'EOF'
---
type: handover
---
a
EOF
cat > "$HANDOVER_DIR/yotam/himmel/2026-06-20-himmel-999-b.md" <<'EOF'
---
type: handover
---
b
EOF

# arm-resume stub: records argv, exits with ARM_STUB_RC (default 0).
ARM_STUB="$TMP/arm-stub.sh"
cat > "$ARM_STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ARM_ARGS_FILE"
exit "${ARM_STUB_RC:-0}"
EOF
chmod +x "$ARM_STUB"
export AUTO_ACTION_ARM_CMD="bash $ARM_STUB"
export ARM_ARGS_FILE="$TMP/arm-args"

run() { ARM_STUB_RC="${ARM_STUB_RC:-0}" bash "$AA" "$@" 2>"$TMP/err"; }

# --- T1: unknown op -------------------------------------------------------
out=$(run bogus-op HIMMEL-777 smart); rc=$?
assert_rc "T1 unknown op" 2 "$rc"

# --- T2: bad time ---------------------------------------------------------
out=$(run arm-resume HIMMEL-777 nope); rc=$?
assert_rc "T2 bad time" 1 "$rc"
out=$(run arm-resume HIMMEL-777 25:00); rc=$?
assert_rc "T2b bad HH:MM" 1 "$rc"

# --- T3: case-insensitive ticket resolve (UPPER arg, lowercase file) ------
out=$(run arm-resume HIMMEL-777 smart); rc=$?
assert_rc "T3 ticket resolves (case-insensitive)" 0 "$rc"
assert_contains "T3 echoes resolved basename" "resolved=2026-06-20-himmel-777-resume.md" "$out"
args=$(cat "$ARM_ARGS_FILE" 2>/dev/null)
assert_contains "T3 arm got --handover resolved path" "2026-06-20-himmel-777-resume.md" "$args"
assert_contains "T3 arm got --time smart" "--time smart" "$args"

# --- T4: ticket only matched under specs/ → excluded → no handover --------
out=$(run arm-resume HIMMEL-888 smart); rc=$?
assert_rc "T4 specs/ excluded → no handover" 3 "$rc"

# --- T5: >1 genuine handover → ambiguous, never silently pick -------------
out=$(run arm-resume HIMMEL-999 smart); rc=$?
assert_rc "T5 ambiguous" 4 "$rc"
assert_contains "T5 lists a candidate" "himmel-999" "$(cat "$TMP/err")"

# --- T6: no match → exit 3 ------------------------------------------------
out=$(run arm-resume HIMMEL-000 smart); rc=$?
assert_rc "T6 no match" 3 "$rc"

# --- T7: non-existent path → exit 3 ---------------------------------------
out=$(run arm-resume "$HANDOVER_DIR/nope.md" smart); rc=$?
assert_rc "T7 non-existent path" 3 "$rc"

# --- T8: path OUTSIDE handover_root → exit 3 (containment) -----------------
OUTSIDE="$TMP/outside.md"; echo "x" > "$OUTSIDE"
out=$(run arm-resume "$OUTSIDE" smart); rc=$?
assert_rc "T8 path outside handover_root rejected" 3 "$rc"

# --- T9: valid path INSIDE root → arms ------------------------------------
INSIDE="$HANDOVER_DIR/yotam/himmel/2026-06-20-himmel-777-resume.md"
out=$(run arm-resume "$INSIDE" 02:00); rc=$?
assert_rc "T9 valid in-root path arms" 0 "$rc"
assert_contains "T9 arm got --time 02:00" "--time 02:00" "$(cat "$ARM_ARGS_FILE")"

# --- T10: arm-resume dedup (rc 3) → auto-action rc 5 (already armed) -------
out=$(ARM_STUB_RC=3 run arm-resume HIMMEL-777 smart); rc=$?
assert_rc "T10 already-armed maps to rc 5" 5 "$rc"

# --- T11: arm-resume other failure (rc 2) → auto-action rc 6 --------------
out=$(ARM_STUB_RC=2 run arm-resume HIMMEL-777 smart); rc=$?
assert_rc "T11 arm failure maps to rc 6" 6 "$rc"

echo "----"
if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILED FAILED"; exit 1; fi
