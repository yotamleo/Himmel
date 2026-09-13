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

# HIMMEL-2975: fixture cmdline for the SENDER's own session (current_session_name).
CMDLINE_FIXTURE="$WORK/cmdline"
printf 'claude\0-n\0HIMMEL-2788-sender\0' > "$CMDLINE_FIXTURE"

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

# --- Case 3: --token is embedded in the bullet, with the sender's author ---
CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$CMDLINE_FIXTURE" bash "$SCRIPT" "$SESSION" "toked ruling" --token abc123 >/dev/null
if grep -qF '[abc123] from=HIMMEL-2788-sender toked ruling' "$INBOX"; then
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

# --- HIMMEL-2975: author line + relay --token refusal -----------------------
SESSION23="HIMMEL-2975-relay-test"
INBOX23="$HANDOVER_DIR/inbox/$SESSION23.md"
CMDLINE_JUDGE="$WORK/cmdline-judge"
printf 'claude\0-n\0HIMMEL-judge-console\0' > "$CMDLINE_JUDGE"

# Case 8: a token bullet carries the sender's own session name as from=.
out="$(CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$CMDLINE_JUDGE" bash "$SCRIPT" "$SESSION23" hello --token t1 2>&1)"; rc=$?
last="$(tail -n1 "$INBOX23" 2>/dev/null)"
if [ "$rc" -eq 0 ] && printf '%s' "$last" | grep -Eq '^- [0-9]{2}:[0-9]{2} \[t1\] from=HIMMEL-judge-console hello$'; then
    pass "token bullet carries from=<sender session>"
else
    fail "token bullet carries from=<sender session> (rc=$rc last='$last' out='$out')"
fi

# Case 9: CONSOLE_SESSION_NAME is ignored -- author is process-derived only.
out="$(CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$CMDLINE_JUDGE" CONSOLE_SESSION_NAME=forged bash "$SCRIPT" "$SESSION23" hello2 --token t2 2>&1)"; rc=$?
last="$(tail -n1 "$INBOX23" 2>/dev/null)"
if [ "$rc" -eq 0 ] && printf '%s' "$last" | grep -Eq '^- [0-9]{2}:[0-9]{2} \[t2\] from=HIMMEL-judge-console hello2$'; then
    pass "CONSOLE_SESSION_NAME cannot forge the author"
else
    fail "CONSOLE_SESSION_NAME cannot forge the author (rc=$rc last='$last' out='$out')"
fi

# Case 10: --token with no resolvable author (no CLAUDE_PID) is refused.
before="$(wc -c < "$INBOX23" 2>/dev/null | tr -d '[:space:]')"
out="$(env -u CLAUDE_PID -u SESSION_NAME_CMDLINE_FILE bash "$SCRIPT" "$SESSION23" hello3 --token t3 2>&1)"; rc=$?
after="$(wc -c < "$INBOX23" 2>/dev/null | tr -d '[:space:]')"
if [ "$rc" -eq 3 ] && [ "$before" = "$after" ]; then
    pass "--token with no resolvable author is refused, inbox unchanged"
else
    fail "--token with no resolvable author is refused, inbox unchanged (rc=$rc before=$before after=$after out='$out')"
fi

# Case 11: a relay cannot send --token, even with a resolvable author.
before="$(wc -c < "$INBOX23" 2>/dev/null | tr -d '[:space:]')"
out="$(CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$CMDLINE_JUDGE" HIMMEL_CONSOLE_RELAY=1 bash "$SCRIPT" "$SESSION23" hello4 --token t4 2>&1)"; rc=$?
after="$(wc -c < "$INBOX23" 2>/dev/null | tr -d '[:space:]')"
if [ "$rc" -eq 3 ] && [ "$before" = "$after" ] && printf '%s' "$out" | grep -qi relay; then
    pass "relay refuses --token"
else
    fail "relay refuses --token (rc=$rc before=$before after=$after out='$out')"
fi

# Case 12: a relay CAN send a no-token bullet, carrying its own author.
out="$(CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$CMDLINE_JUDGE" HIMMEL_CONSOLE_RELAY=1 bash "$SCRIPT" "$SESSION23" halt 2>&1)"; rc=$?
last="$(tail -n1 "$INBOX23" 2>/dev/null)"
if [ "$rc" -eq 0 ] && printf '%s' "$last" | grep -Eq '^- [0-9]{2}:[0-9]{2} from=HIMMEL-judge-console halt$'; then
    pass "relay's no-token bullet carries from=<sender session>"
else
    fail "relay's no-token bullet carries from=<sender session> (rc=$rc last='$last' out='$out')"
fi

# Case 13: no token, no CLAUDE_PID -> from=unknown, not refused.
out="$(env -u CLAUDE_PID -u SESSION_NAME_CMDLINE_FILE bash "$SCRIPT" "$SESSION23" nobody 2>&1)"; rc=$?
last="$(tail -n1 "$INBOX23" 2>/dev/null)"
if [ "$rc" -eq 0 ] && printf '%s' "$last" | grep -Eq '^- [0-9]{2}:[0-9]{2} from=unknown nobody$'; then
    pass "no token, no CLAUDE_PID -> from=unknown"
else
    fail "no token, no CLAUDE_PID -> from=unknown (rc=$rc last='$last' out='$out')"
fi

# HIMMEL-2795: force overlapping read-modify-write snapshots. Writer two
# signals before flock (fixed) or mv (baseline); writer one pauses at mv.
# flock is a required prerequisite for this case (CodeRabbit, HIMMEL-2790):
# without it REAL_FLOCK is empty and the stub execs an empty command, so both
# writers would fail before the race assertion ever runs.
if ! REAL_FLOCK="$(command -v flock)"; then
    printf 'SKIP: flock not installed — doc race test requires flock\n'
else
mkdir -p "$WORK/race-bin" "$WORK/race"
DOC_RACE="$WORK/race"
REAL_MV="$(command -v mv)"
export DOC_RACE REAL_MV REAL_FLOCK
cat > "$WORK/race-bin/mv" <<'STUB'
#!/usr/bin/env bash
if [ "$RACE_WRITER" = one ]; then
    touch "$DOC_RACE/ready"
    for ((i=0; i<1000; i++)); do
        [ ! -f "$DOC_RACE/release" ] || exec "$REAL_MV" "$@"
        sleep .01
    done
    exit 1
fi
touch "$DOC_RACE/second"
exec "$REAL_MV" "$@"
STUB
cat > "$WORK/race-bin/flock" <<'STUB'
#!/usr/bin/env bash
[ "$RACE_WRITER" != two ] || touch "$DOC_RACE/second"
exec "$REAL_FLOCK" "$@"
STUB
chmod +x "$WORK/race-bin/mv" "$WORK/race-bin/flock"
wait_race_file() {
    local i
    for ((i=0; i<1000; i++)); do
        [ ! -f "$1" ] || return 0
        sleep .01
    done
    return 1
}
DOC_RACE_FILE="$WORK/concurrent.md"
printf '# Leg\n## Console Rulings\n- existing\n## Results\nkeep this\n' > "$DOC_RACE_FILE"
PATH="$WORK/race-bin:$PATH" RACE_WRITER=one bash "$SCRIPT" race-one 'writer one' --doc "$DOC_RACE_FILE" > "$WORK/one" &
pid1=$!
wait_race_file "$DOC_RACE/ready" || fail "doc race: first writer reached mv"
PATH="$WORK/race-bin:$PATH" RACE_WRITER=two bash "$SCRIPT" race-two 'writer two' --doc "$DOC_RACE_FILE" > "$WORK/two" &
pid2=$!
wait_race_file "$DOC_RACE/second" || fail "doc race: second writer overlapped"
touch "$DOC_RACE/release"
wait "$pid1" || fail "doc race: first writer exited successfully"
wait "$pid2" || fail "doc race: second writer exited successfully"
if grep -qF 'writer one' "$DOC_RACE_FILE" && grep -qF 'writer two' "$DOC_RACE_FILE" && grep -qF 'keep this' "$DOC_RACE_FILE"; then
    pass "concurrent doc mirrors preserve both rulings and existing results"
else
    fail "concurrent doc mirrors lost a ruling or existing results"
fi
fi

# HIMMEL-2790 (CodeRabbit): a pre-existing, wrongly-permissioned lock
# directory must be tightened to 700 — mkdir -m only sets the mode at
# creation, so a leftover directory from an older run or a looser umask was
# previously accepted as-is.
LOCK_DIR="${TMPDIR:-/tmp}/himmel-inbox-doc-$UID"
mkdir -p "$LOCK_DIR"
chmod 755 "$LOCK_DIR"
DOC_PERM="$WORK/perm.md"
printf '# Leg\n## Console Rulings\n- existing\n' > "$DOC_PERM"
bash "$SCRIPT" perm-leg 'perm ruling' --doc "$DOC_PERM" >/dev/null
lock_mode="$(stat -c '%a' "$LOCK_DIR")"
if [ "$lock_mode" = "700" ]; then
    pass "pre-existing lock directory is tightened to 700"
else
    fail "pre-existing lock directory left at $lock_mode instead of 700"
fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "SOME FAILED"; exit 1
