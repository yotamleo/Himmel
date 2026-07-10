#!/usr/bin/env bash
# test-arm-resume-queue-lock.sh -- regression test for the HIMMEL-856
# queue-lock + cross-machine arms-registry integration added to
# scripts/handover/arm-resume.sh (rc=7 / rc=8 refusals + overrides).
#
# Kept SEPARATE from the (already large) test-arm-resume.sh so this
# ticket's surface stays independently reviewable; both suites run
# against the same arm-resume.sh and share its stubbing conventions
# (PATH-stubbed schtasks/atq/at so no real scheduler job is ever
# created; a throwaway WORKSPACE_TRUST_CONFIG and SKILL_TELEMETRY_DIR
# so no operator state is touched).
#
# Usage: bash scripts/handover/test-arm-resume-queue-lock.sh
# Exit:  0 = all pass, 1 = one or more failures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARM="$SCRIPT_DIR/arm-resume.sh"
QL="$SCRIPT_DIR/queue-lock.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Hermetic: fresh handover root, no real scheduler, no real telemetry/trust
# writes (same shields test-arm-resume.sh uses).
HANDOVER_DIR="$TMP/statedocs/handovers"
mkdir -p "$HANDOVER_DIR"
export HANDOVER_DIR
export SKILL_TELEMETRY_DIR="$TMP/telemetry"
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
unset QUEUE_LOCK_TAKEOVER QUEUE_LOCK_TTL_SECONDS ARM_DUP_OK 2>/dev/null || true

FUTURE_TIME="23:59"
HO="$HANDOVER_DIR/HIMMEL-856-test/next-session-1.md"
mkdir -p "$(dirname "$HO")"
printf -- '---\nsession_kind: test\n---\n# HIMMEL-856 test handover\n' > "$HO"

FAILED=0
assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label -- expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}
assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label -- output missing: $needle"; FAILED=$((FAILED + 1)) ;;
    esac
}
assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL $label -- output unexpectedly contains: $needle"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS $label" ;;
    esac
}

# Empty-scheduler stub (same pattern as test-arm-resume.sh SCHED_STUB_T17):
# /query (and atq/at) return nothing, rc 0 -- reads as "no existing jobs" so
# the pre-existing same-machine dedup/collision checks never interfere with
# these HIMMEL-856-specific assertions.
SCHED_STUB="$TMP/sched-stub"
mkdir -p "$SCHED_STUB"
cat > "$SCHED_STUB/schtasks" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SCHED_STUB/atq" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SCHED_STUB/at" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SCHED_STUB/schtasks" "$SCHED_STUB/atq" "$SCHED_STUB/at"
export PATH="$SCHED_STUB:$PATH"

# --- T1: no lock, no registry -> plain dry-run arm succeeds -----------------
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T1: no lock/registry, dry-run arm" 0 "$rc"

# --- T2: queue lock FRESH -> arm refused rc=7 --------------------------------
bash "$QL" acquire "$HO" "live-session" >/dev/null 2>&1
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T2: FRESH queue lock refuses arm" 7 "$rc"
assert_contains "T2: stderr names the live holder" "live-session" "$out"
assert_contains "T2: stderr names the override" "QUEUE_LOCK_TAKEOVER" "$out"

# --- T3: QUEUE_LOCK_TAKEOVER=1 overrides the FRESH refusal -> rc=0, WARN ----
out=$(QUEUE_LOCK_TAKEOVER=1 bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T3: QUEUE_LOCK_TAKEOVER=1 overrides FRESH refusal" 0 "$rc"
assert_contains "T3: WARN present on override" "WARN arm-resume: queue lock is FRESH" "$out"

# --- T4: release -> arm succeeds again without any override -----------------
bash "$QL" release "$HO" "live-session" >/dev/null 2>&1
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T4: arm succeeds after release" 0 "$rc"

# --- T5: STALE queue lock (TTL=0) does NOT refuse the arm --------------------
bash "$QL" acquire "$HO" "old-session" >/dev/null 2>&1
out=$(QUEUE_LOCK_TTL_SECONDS=0 bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T5: STALE lock (TTL=0) does not block arming" 0 "$rc"
bash "$QL" release "$HO" "old-session" >/dev/null 2>&1

# --- T6: arms.jsonl entry for the SAME host -> not a cross-machine dup ------
mkdir -p "$HANDOVER_DIR/.locks"
THIS_HOST=$(hostname 2>/dev/null || echo "${COMPUTERNAME:-${HOSTNAME:-unknown-host}}")
printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-same-host"}\n' \
    "$THIS_HOST" "$HO" > "$HANDOVER_DIR/.locks/arms.jsonl"
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T6: same-host registry entry is not a cross-machine dup" 0 "$rc"

# --- T7: arms.jsonl entry for a DIFFERENT host, SAME handover -> rc=8 -------
printf '{"host":"other-host","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-other-host"}\n' \
    "$HO" > "$HANDOVER_DIR/.locks/arms.jsonl"
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T7: cross-host pending arm refuses (rc=8)" 8 "$rc"
assert_contains "T7: stderr names the other host" "other-host" "$out"
assert_contains "T7: stderr names the override" "ARM_DUP_OK" "$out"

# --- T8: ARM_DUP_OK=1 overrides the cross-host refusal -> rc=0, WARN --------
out=$(ARM_DUP_OK=1 bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T8: ARM_DUP_OK=1 overrides cross-host refusal" 0 "$rc"
assert_contains "T8: WARN present on override" "WARN arm-resume: this handover already has a PENDING arm" "$out"

# --- T9: arms.jsonl entry for an UNRELATED handover -> no false positive ----
OTHER_HO="$HANDOVER_DIR/HIMMEL-856-test/next-session-2.md"
: > "$OTHER_HO"
printf '{"host":"other-host","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-unrelated"}\n' \
    "$OTHER_HO" > "$HANDOVER_DIR/.locks/arms.jsonl"
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T9: registry entry for a DIFFERENT handover is not a false-positive dup" 0 "$rc"
rm -f "$HANDOVER_DIR/.locks/arms.jsonl"

# --- T10: a REAL (non-dry-run) arm against the stubbed scheduler appends a
#          well-formed line to arms.jsonl ------------------------------------
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" 2>&1)
rc=$?
assert_rc "T10: stubbed real arm succeeds" 0 "$rc"
if [ -f "$HANDOVER_DIR/.locks/arms.jsonl" ] \
    && grep -q "\"handover\":\"$HO\"" "$HANDOVER_DIR/.locks/arms.jsonl" \
    && grep -q '"task-name":"HIMMEL-Resume-' "$HANDOVER_DIR/.locks/arms.jsonl"; then
    echo "PASS T10: arms.jsonl gained a well-formed record for this arm"
else
    echo "FAIL T10: arms.jsonl missing/malformed after a real arm ($(cat "$HANDOVER_DIR/.locks/arms.jsonl" 2>/dev/null || echo MISSING))"
    FAILED=$((FAILED + 1))
fi
assert_not_contains "T10: dry-run banner absent on a real (non-dry-run) arm" "dry-run complete" "$out"

# --- T11: post-append double-arm detection (HIMMEL-856 CR, codex-1) ---------
# The registry check-then-append pair cannot be atomic across machines; the
# mitigation is a re-read AFTER our own append that warns LOUDLY when another
# host's arm for the same handover is visible. Simulate the double-arm by
# pre-seeding the other host's line and arming with ARM_DUP_OK=1 (so the
# pre-check lets us through, standing in for "their line landed in the
# check->append window"): the arm must succeed (rc=0 -- the warning is
# advisory, never a failure) AND the post-append warning must fire, naming
# the other host.
HO11="$HANDOVER_DIR/HIMMEL-856-test/next-session-11.md"
printf -- '---\nsession_kind: test\n---\n# HIMMEL-856 t11 handover\n' > "$HO11"
printf '{"host":"rival-host","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-rival"}\n' \
    "$HO11" > "$HANDOVER_DIR/.locks/arms.jsonl"
out=$(ARM_DUP_OK=1 bash "$ARM" --time "$FUTURE_TIME" --handover "$HO11" 2>&1)
rc=$?
assert_rc "T11: double-armed arm still succeeds (warning is advisory)" 0 "$rc"
assert_contains "T11: post-append DOUBLE-ARM warning fires" "DOUBLE-ARM DETECTED" "$out"
assert_contains "T11: warning names the rival host" "rival-host" "$out"
# Our own record was still appended alongside the rival's.
if grep -q "\"handover\":\"$HO11\"" "$HANDOVER_DIR/.locks/arms.jsonl" \
    && [ "$(grep -c "\"handover\":\"$HO11\"" "$HANDOVER_DIR/.locks/arms.jsonl")" -eq 2 ]; then
    echo "PASS T11: registry holds both hosts' records after the double-arm"
else
    echo "FAIL T11: registry does not hold both records ($(cat "$HANDOVER_DIR/.locks/arms.jsonl" 2>/dev/null || echo MISSING))"
    FAILED=$((FAILED + 1))
fi
rm -f "$HANDOVER_DIR/.locks/arms.jsonl"

# --- T12: no false post-append warning on a clean single-host arm -----------
HO12="$HANDOVER_DIR/HIMMEL-856-test/next-session-12.md"
printf -- '---\nsession_kind: test\n---\n# HIMMEL-856 t12 handover\n' > "$HO12"
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO12" 2>&1)
rc=$?
assert_rc "T12: clean single-host arm succeeds" 0 "$rc"
assert_not_contains "T12: no DOUBLE-ARM warning on a clean arm" "DOUBLE-ARM DETECTED" "$out"

# --- T13: missing queue-lock.sh -> WARN + arm proceeds (imp-a) ---------------
# Copy arm-resume.sh (+ its hard-required libs) into an isolated tree that
# has NO queue-lock.sh next to it -- the check must WARN and skip, matching
# the missing-handover-root WARN contract, never silently pass or fail.
FAKE="$TMP/no-ql"
mkdir -p "$FAKE/handover" "$FAKE/lib"
cp "$SCRIPT_DIR/arm-resume.sh" "$FAKE/handover/arm-resume.sh"
cp "$SCRIPT_DIR/../lib/py-armor.sh" "$FAKE/lib/py-armor.sh"
cp "$SCRIPT_DIR/../lib/handover-path.sh" "$FAKE/lib/handover-path.sh"
cp "$SCRIPT_DIR/../lib/telemetry.sh" "$FAKE/lib/telemetry.sh" 2>/dev/null || true
HO13="$HANDOVER_DIR/HIMMEL-856-test/next-session-13.md"
printf -- '---\nsession_kind: test\n---\n# HIMMEL-856 t13 handover\n' > "$HO13"
out=$(bash "$FAKE/handover/arm-resume.sh" --time "$FUTURE_TIME" --handover "$HO13" --dry-run 2>&1)
rc=$?
assert_rc "T13: arm proceeds with queue-lock.sh missing" 0 "$rc"
assert_contains "T13: WARN names the missing queue-lock.sh" "queue-lock.sh not found" "$out"

# --- T14: unexpected queue-lock status rc -> WARN + arm proceeds (imp-b) ----
# Same isolated tree, now with a stub queue-lock.sh that exits rc=5 (not
# 0/11/12): the check must WARN 'proceeding' instead of silently treating
# a broken status probe as a verified-free queue.
printf '#!/usr/bin/env bash\necho "stub queue-lock exploded" >&2\nexit 5\n' > "$FAKE/handover/queue-lock.sh"
out=$(bash "$FAKE/handover/arm-resume.sh" --time "$FUTURE_TIME" --handover "$HO13" --dry-run 2>&1)
rc=$?
assert_rc "T14: arm proceeds despite a broken status probe" 0 "$rc"
assert_contains "T14: WARN reports the unexpected status rc" "queue-lock status failed (rc=5)" "$out"

echo "---"
echo "FAILED=$FAILED"
[ "$FAILED" -eq 0 ]
