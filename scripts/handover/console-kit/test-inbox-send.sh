#!/usr/bin/env bash
# test-inbox-send.sh — HIMMEL-2788. Exercises inbox-send.sh: append-only
# writes, --doc mirroring into "## Console Rulings", traversal/whitespace
# refusal, and --pending listing. bash 3.2-safe.
#
# PLATFORM GUARD: no .ps1 twin, by design, not oversight — this tests
# inbox-send.sh, itself Linux-only (see its header).
# Run: bash scripts/handover/console-kit/test-inbox-send.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/inbox-send.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/inbox-send-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

HANDOVER_DIR="$WORK/handover-root"
mkdir -p "$HANDOVER_DIR"
export HANDOVER_DIR

SESSION="HIMMEL-2788-test-leg"
INBOX="$HANDOVER_DIR/inbox/$SESSION.md"

# --- Case 1: append writes one bullet ---------------------------------------
out="$(bash "$SCRIPT" "$SESSION" "first ruling")"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$INBOX" ] && grep -qF 'first ruling' "$INBOX"; then
    pass "appends a bullet to the session inbox"
else
    fail "appends a bullet to the session inbox (rc=$rc out='$out')"
fi

# --- Case 2: append-only — a second call adds, never rewrites ---------------
bash "$SCRIPT" "$SESSION" "second ruling" >/dev/null
lines="$(wc -l < "$INBOX" | tr -d '[:space:]')"
if [ "$lines" -eq 2 ] && grep -qF 'first ruling' "$INBOX" && grep -qF 'second ruling' "$INBOX"; then
    pass "append-only: both bullets present, neither overwritten"
else
    fail "append-only: both bullets present, neither overwritten (lines=$lines)"
fi

# --- Case 3: --token is embedded in the bullet ------------------------------
bash "$SCRIPT" "$SESSION" "toked ruling" --token abc123 >/dev/null
if grep -qF '[abc123] toked ruling' "$INBOX"; then
    pass "--token embeds the RETASK token in the bullet"
else
    fail "--token embeds the RETASK token in the bullet"
fi

# --- Case 4: --doc mirrors into an existing "## Console Rulings" section ---
DOC="$WORK/leg-doc.md"
printf '# Leg doc\n\n## Console Rulings (newest at the bottom)\n- 08:00 existing bullet\n\n## Results\nsome text\n' > "$DOC"
bash "$SCRIPT" "$SESSION" "mirrored ruling" --doc "$DOC" >/dev/null
if grep -qF 'mirrored ruling' "$DOC"; then
    pass "--doc mirrors the bullet into the doc"
else
    fail "--doc mirrors the bullet into the doc"
fi
# must land inside the Console Rulings section, before ## Results
before_results="$(awk '/^## Console Rulings/{f=1} f&&/mirrored ruling/{print "yes"} /^## Results/{exit}' "$DOC")"
if [ "$before_results" = "yes" ]; then
    pass "--doc mirror lands inside the Console Rulings section, not after it"
else
    fail "--doc mirror lands inside the Console Rulings section, not after it"
fi

# --- Case 5: --doc creates the section when absent --------------------------
DOC2="$WORK/leg-doc-no-section.md"
printf '# Leg doc\n\n## Results\nsome text\n' > "$DOC2"
bash "$SCRIPT" "$SESSION" "created-section ruling" --doc "$DOC2" >/dev/null
if grep -qF '## Console Rulings' "$DOC2" && grep -qF 'created-section ruling' "$DOC2"; then
    pass "--doc creates a Console Rulings section when none exists"
else
    fail "--doc creates a Console Rulings section when none exists"
fi

# --- Case 6: session-name traversal refused ---------------------------------
out="$(bash "$SCRIPT" "../../etc/passwd" "text" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -f "$HANDOVER_DIR/inbox/../../etc/passwd.md" ]; then
    pass "traversal session name refused (rc=$rc)"
else
    fail "traversal session name refused (rc=$rc out='$out')"
fi

out="$(bash "$SCRIPT" "foo/bar" "text" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
    pass "slash in session name refused"
else
    fail "slash in session name refused (rc=$rc out='$out')"
fi

out="$(bash "$SCRIPT" "foo bar" "text" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
    pass "whitespace in session name refused"
else
    fail "whitespace in session name refused (rc=$rc out='$out')"
fi

# --- Case 7: --pending lists only sessions with undelivered content --------
SESSION_PENDING="HIMMEL-2788-pending-leg"
bash "$SCRIPT" "$SESSION_PENDING" "not yet delivered" >/dev/null
mkdir -p "$HANDOVER_DIR/inbox/.cursor"
# Mark $SESSION fully delivered (cursor == current size) so it must NOT
# appear in --pending, while $SESSION_PENDING (no cursor yet) must.
size="$(wc -c < "$INBOX" | tr -d '[:space:]')"
printf '%s\n' "$size" > "$HANDOVER_DIR/inbox/.cursor/$SESSION"

out="$(bash "$SCRIPT" --pending)"
if printf '%s' "$out" | grep -qF "$SESSION_PENDING"; then
    pass "--pending lists a session with undelivered content"
else
    fail "--pending lists a session with undelivered content (out='$out')"
fi
if printf '%s' "$out" | grep -qF "$SESSION "; then
    fail "--pending must not list a fully-delivered session (out='$out')"
else
    pass "--pending does not list a fully-delivered session"
fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "SOME FAILED"; exit 1
