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

# --- T15: re-arming the SAME handover from the SAME host replaces its own --
# prior arms.jsonl record instead of accumulating a second one (HIMMEL-882).
# A stale same-host record left behind by a repeated re-arm/--force would
# otherwise sit in the append-only registry forever -- harmless to THIS
# host (foreign-hits only looks at OTHER hosts) but a permanent rc=8 trap
# for the NEXT host that tries to arm this same handover.
HO15="$HANDOVER_DIR/HIMMEL-856-test/next-session-15.md"
printf -- '---\nsession_kind: test\n---\n# HIMMEL-856 t15 handover\n' > "$HO15"
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO15" 2>&1)
rc=$?
assert_rc "T15: first real arm succeeds" 0 "$rc"
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO15" 2>&1)
rc=$?
assert_rc "T15: second real arm (re-arm, same host) succeeds" 0 "$rc"
n=$(grep -c "\"handover\":\"$HO15\"" "$HANDOVER_DIR/.locks/arms.jsonl" 2>/dev/null || echo 0)
if [ "$n" -eq 1 ]; then
    echo "PASS T15: exactly one record survives repeated same-host re-arms (got $n)"
else
    echo "FAIL T15: expected exactly 1 record after 2 same-host re-arms, got $n ($(cat "$HANDOVER_DIR/.locks/arms.jsonl" 2>/dev/null))"
    FAILED=$((FAILED + 1))
fi
rm -f "$HANDOVER_DIR/.locks/arms.jsonl"

# --- T16: a FIRED foreign-host record no longer blocks a re-arm (HIMMEL-882)
# queue-lock.sh's acquire marks a record "fired":"true" once the armed
# session actually starts; that record must stop counting as a PENDING
# cross-host dup from then on.
HO16="$HANDOVER_DIR/HIMMEL-856-test/next-session-16.md"
printf -- '---\nsession_kind: test\n---\n# HIMMEL-856 t16 handover\n' > "$HO16"
printf '{"host":"other-host","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-fired","fired":"true"}\n' \
    "$HO16" > "$HANDOVER_DIR/.locks/arms.jsonl"
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO16" --dry-run 2>&1)
rc=$?
assert_rc "T16: fired foreign-host record no longer blocks re-arm" 0 "$rc"
assert_not_contains "T16: no rc=8 PENDING-arm refusal for a fired record" "already has a PENDING arm" "$out"
rm -f "$HANDOVER_DIR/.locks/arms.jsonl"

# --- T17: a STILL-LIVE (unfired) foreign-host record still refuses rc=8 ----
# (HIMMEL-882 regression guard) -- confirms the fired-skip added for T16 is
# scoped to records actually marked "fired":"true" and does not silently
# widen to every foreign record.
HO17="$HANDOVER_DIR/HIMMEL-856-test/next-session-17b.md"
printf -- '---\nsession_kind: test\n---\n# HIMMEL-856 t17 handover\n' > "$HO17"
printf '{"host":"other-host","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-still-live"}\n' \
    "$HO17" > "$HANDOVER_DIR/.locks/arms.jsonl"
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO17" --dry-run 2>&1)
rc=$?
assert_rc "T17: still-live (unfired) foreign-host record still refuses rc=8" 8 "$rc"
rm -f "$HANDOVER_DIR/.locks/arms.jsonl"

# --- T18: MIXED registry -- fired + pending for the SAME handover on -------
# DIFFERENT hosts (round-2 addendum): the fired record is skipped but the
# pending one still refuses rc=8, from one multi-line file.
HO18="$HANDOVER_DIR/HIMMEL-856-test/next-session-18.md"
printf -- '---\nsession_kind: test\n---\n# HIMMEL-856 t18 handover\n' > "$HO18"
{
    printf '{"host":"fired-host","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t18-fired","fired":"true"}\n' "$HO18"
    printf '{"host":"pending-host","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t18-pending"}\n' "$HO18"
} > "$HANDOVER_DIR/.locks/arms.jsonl"
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO18" --dry-run 2>&1)
rc=$?
assert_rc "T18: mixed registry still refuses on the PENDING record" 8 "$rc"
assert_contains "T18: refusal names the pending host" "pending-host" "$out"
assert_not_contains "T18: refusal does not list the fired host as a hit" "fired-host" "$out"
rm -f "$HANDOVER_DIR/.locks/arms.jsonl"

# --- T19: backslash handover path -- prune still matches (round-2 item 3) --
# The registry stores JSON-escaped values (backslashes doubled); pre-fix
# the raw-vs-escaped compare silently disabled the same-host prune, so two
# arms with a backslash path left two records. On Windows/Git-Bash use the
# real cygpath -w (backslash) form of the handover; on POSIX a literal
# backslash is a legal filename character -- both exercise the same
# escaped-needle compare.
HO19P="$HANDOVER_DIR/HIMMEL-856-test/next-session-19.md"
printf -- '---\nsession_kind: test\n---\n# HIMMEL-856 t19 handover\n' > "$HO19P"
if command -v cygpath >/dev/null 2>&1; then
    HO19=$(cygpath -w "$HO19P")
else
    HO19="$HANDOVER_DIR/HIMMEL-856-test/"'back\slash-19.md'
    printf -- '---\nsession_kind: test\n---\n# HIMMEL-856 t19 handover\n' > "$HO19"
fi
HO19_ESC=$(printf '%s' "$HO19" | sed -e 's/\\/\\\\/g')
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO19" 2>&1)
rc=$?
assert_rc "T19: first arm with a backslash path succeeds" 0 "$rc"
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO19" 2>&1)
rc=$?
assert_rc "T19: second arm (re-arm) with a backslash path succeeds" 0 "$rc"
n=$(grep -cF "\"handover\":\"$HO19_ESC\"" "$HANDOVER_DIR/.locks/arms.jsonl" 2>/dev/null || echo 0)
if [ "$n" -eq 1 ]; then
    echo "PASS T19: escaped-path prune matched -- exactly 1 record after 2 re-arms"
else
    echo "FAIL T19: expected 1 record for the backslash path, got $n ($(cat "$HANDOVER_DIR/.locks/arms.jsonl" 2>/dev/null))"
    FAILED=$((FAILED + 1))
fi
rm -f "$HANDOVER_DIR/.locks/arms.jsonl"

# --- T20: registry unwritable -> mutex timeout WARN + the arm still --------
# succeeds (round-2 fail-open contract, addendum item). Portable trigger: a
# FILE where the .locks dir should be -- mkdir -p fails and the mutex mkdir
# can never succeed (parent is a file), so the rewrite is skipped after the
# bounded ~4s wait. No chmod tricks (they don't hold on Windows).
HD20="$TMP/statedocs-t20/handovers"
mkdir -p "$HD20/HIMMEL-856-test"
: > "$HD20/.locks"   # a FILE squatting on the .locks DIR path
HO20="$HD20/HIMMEL-856-test/next-session-20.md"
printf -- '---\nsession_kind: test\n---\n# HIMMEL-856 t20 handover\n' > "$HO20"
out=$(HANDOVER_DIR="$HD20" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO20" 2>&1)
rc=$?
assert_rc "T20: arm still succeeds when the registry root is unwritable" 0 "$rc"
assert_contains "T20: WARN names the failed registry append" "failed to append the arms.jsonl registry record" "$out"

# --- T21: cross-script writer race -- arm (prune+append) vs acquire --------
# (consume) on the SAME registry, different handovers (round-2 High).
# Pre-mutex, the loser's rewrite was overwritten by the winner's mv (lost
# update). A few full-arm rounds are enough here -- the 20-round hammer for
# the mutex itself lives in test-queue-lock.sh T25. End state per round
# (retention shape, round-3): the arm's NEW record present, the acquire's
# record CONSUMED -- exactly 1 line, no matter who won the mutex first.
T21_BAD=""
t21_i=0
while [ "$t21_i" -lt 6 ]; do
    HOA="$HANDOVER_DIR/HIMMEL-856-test/t21-arm-$t21_i.md"
    printf -- '---\nsession_kind: test\n---\n# HIMMEL-856 t21 handover\n' > "$HOA"
    HOB="$HANDOVER_DIR/HIMMEL-856-test/t21-acq-$t21_i.md"
    THIS_HOST=$(hostname 2>/dev/null || echo "${COMPUTERNAME:-${HOSTNAME:-unknown-host}}")
    printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t21-acq"}\n' \
        "$THIS_HOST" "$HOB" > "$HANDOVER_DIR/.locks/arms.jsonl"
    ( bash "$ARM" --time "$FUTURE_TIME" --handover "$HOA" >/dev/null 2>&1 ) &
    ( bash "$QL" acquire "$HOB" "t21-acq-$t21_i" >/dev/null 2>&1 ) &
    wait
    if ! grep -qF "\"handover\":\"$HOA\"" "$HANDOVER_DIR/.locks/arms.jsonl" \
        || grep -q 'HIMMEL-Resume-t21-acq' "$HANDOVER_DIR/.locks/arms.jsonl" \
        || [ "$(wc -l < "$HANDOVER_DIR/.locks/arms.jsonl")" -ne 1 ]; then
        T21_BAD="round $t21_i: $(cat "$HANDOVER_DIR/.locks/arms.jsonl" 2>/dev/null)"
        break
    fi
    t21_i=$((t21_i + 1))
done
if [ -z "$T21_BAD" ]; then
    echo "PASS T21: no lost update across 6 arm-vs-acquire race rounds"
else
    echo "FAIL T21: cross-script race lost an update ($T21_BAD)"
    FAILED=$((FAILED + 1))
fi
rm -f "$HANDOVER_DIR/.locks/arms.jsonl"

# --- T22: a REAL arm garbage-collects legacy fired-marked lines ------------
# (round-3 retention): a '"fired":"true"' line (written by the round-1/2
# marking revision) is inert -- the rewrite drops it in passing, so the
# registry stays O(active arms). Keeps the T16 INTENT (a fired foreign
# record must not refuse re-arms) whether the line is still present
# (dry-run path, T16) or pruned (this rewrite path).
HO22="$HANDOVER_DIR/HIMMEL-856-test/next-session-22b.md"
printf -- '---\nsession_kind: test\n---\n# HIMMEL-856 t22 handover\n' > "$HO22"
{
    printf '{"host":"other-host","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t22-legacy-fired","fired":"true"}\n' "$HO22"
    printf '{"host":"other-host","handover":"t22-unrelated.md","fire-at":"202601010000","task-name":"HIMMEL-Resume-t22-pending-bystander"}\n'
} > "$HANDOVER_DIR/.locks/arms.jsonl"
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO22" 2>&1)
rc=$?
assert_rc "T22: real arm succeeds over a legacy fired record" 0 "$rc"
if ! grep -q 'HIMMEL-Resume-t22-legacy-fired' "$HANDOVER_DIR/.locks/arms.jsonl" \
    && grep -q 'HIMMEL-Resume-t22-pending-bystander' "$HANDOVER_DIR/.locks/arms.jsonl" \
    && grep -qF "\"handover\":\"$HO22\"" "$HANDOVER_DIR/.locks/arms.jsonl"; then
    echo "PASS T22: legacy fired line pruned; pending bystander + new record survive"
else
    echo "FAIL T22: retention GC wrong ($(cat "$HANDOVER_DIR/.locks/arms.jsonl" 2>/dev/null))"
    FAILED=$((FAILED + 1))
fi
rm -f "$HANDOVER_DIR/.locks/arms.jsonl"

echo "---"
echo "FAILED=$FAILED"
[ "$FAILED" -eq 0 ]
