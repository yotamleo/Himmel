#!/usr/bin/env bash
# Smoke tests for scripts/hooks/auto-arm-on-subagent-cap.sh (HIMMEL-276).
#
# Stubs arm-resume.sh via AUTO_ARM_BIN; never touches the real scheduler.
# Each test feeds a PostToolUse JSON payload on stdin.
set -u -o pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/auto-arm-on-subagent-cap.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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
    local desc="$1" mode="$2" path="$3"
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
    if [ -f "$file" ] && LC_ALL=C grep -qF -- "$pattern" "$file"; then
        echo "  PASS  $desc"
        pass=$((pass+1))
    else
        echo "  FAIL  $desc (pattern '$pattern' not in $file)"
        fail=$((fail+1))
    fi
}

count_glob() {
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

HANDOVER_TEST_DIR="$TMP/handovers"
mkdir -p "$HANDOVER_TEST_DIR"
STDERR_LOG="$TMP/stderr.log"

# Helper: run hook with a JSON payload string.
# $1 = state dir, $2 = payload (JSON string)
run_hook() {
    printf '%s\n' "$2" | \
    AUTO_ARM_STATE_DIR="$1" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" \
    CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" >/dev/null 2>"$STDERR_LOG"
}

# Helper: run hook with session_id in payload.
run_hook_sid() {
    # $1=state, $2=session_id, $3=cap message, $4=arm stub rc (optional)
    local payload
    payload=$(printf '{"session_id":"%s","tool_name":"Agent","tool_response":{"type":"tool_result","content":"%s"}}' "$2" "$3")
    printf '%s\n' "$payload" | \
    AUTO_ARM_STATE_DIR="$1" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" ARM_STUB_RC="${4:-0}" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" \
    CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" >/dev/null 2>"$STDERR_LOG"
}

# Standard cap payload template.
cap_payload() {
    # $1 = session_id (optional)
    local sid="${1:-sess-001}"
    printf '{"session_id":"%s","tool_name":"Agent","tool_response":{"type":"tool_result","content":"You have hit your session limit. Try again after 2026-06-10T18:00:00Z."}}' "$sid"
}

echo "Test 1: kill switch AUTO_ARM_DISABLE=1 — quiet no-op regardless of cap sentinel"
S="$TMP/s1"; mkdir -p "$S"
rm -f "$ARM_LOG"
printf '%s\n' "$(cap_payload 'sid-001')" | \
    AUTO_ARM_DISABLE=1 \
    AUTO_ARM_STATE_DIR="$S" AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" >/dev/null 2>"$STDERR_LOG"
assert_rc "disabled hook exits 0" 0 $?
assert_file "no arm call when disabled" absent "$ARM_LOG"

echo "Test 1b: AUTO_ARM_SUBAGENT_DISABLE=1 — hook-only kill switch"
rm -f "$ARM_LOG"
printf '%s\n' "$(cap_payload 'sid-001b')" | \
    AUTO_ARM_SUBAGENT_DISABLE=1 \
    AUTO_ARM_STATE_DIR="$S" AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" >/dev/null 2>"$STDERR_LOG"
assert_rc "subagent-disable exits 0" 0 $?
assert_file "no arm call with subagent disable" absent "$ARM_LOG"

echo "Test 2: non-Agent tool — quiet no-op"
S="$TMP/s2"; mkdir -p "$S"
rm -f "$ARM_LOG"
run_hook "$S" '{"session_id":"sid-002","tool_name":"Bash","tool_response":{"type":"tool_result","content":"You have hit your session limit"}}'
assert_rc "non-Agent tool exits 0" 0 $?
assert_file "no arm call for non-Agent tool" absent "$ARM_LOG"

echo "Test 3: Agent tool result WITHOUT cap sentinel — quiet no-op"
S="$TMP/s3"; mkdir -p "$S"
rm -f "$ARM_LOG"
run_hook "$S" '{"session_id":"sid-003","tool_name":"Agent","tool_response":{"type":"tool_result","content":"Task completed successfully. All tests passed."}}'
assert_rc "no-sentinel run exits 0" 0 $?
assert_file "no arm call without sentinel" absent "$ARM_LOG"

echo "Test 4: primary sentinel 'You have hit your session limit' — arm fires, one-shot block"
S="$TMP/s4"; mkdir -p "$S"
rm -f "$ARM_LOG"
run_hook "$S" "$(cap_payload 'sid-004')"
assert_rc "primary-sentinel run exits 2 (one-shot block)" 2 $?
assert_file "arm stub invoked" present "$ARM_LOG"
assert_grep "arm invoked with --time smart" "--time smart" "$ARM_LOG"
assert_grep "arm invoked with --handover" "--handover" "$ARM_LOG"
handover_arg=$(LC_ALL=C sed -E 's/.*--handover ([^ ]+).*/\1/' "$ARM_LOG" | head -1)
assert_file "snapshot passed to arm exists" present "$handover_arg"
snap_count=$(count_glob "$HANDOVER_TEST_DIR" 'auto-arm-status-sub-*.md')
if [ "$snap_count" = "1" ]; then
    echo "  PASS  exactly one status snapshot in handover root"
    pass=$((pass+1))
else
    echo "  FAIL  exactly one status snapshot in handover root (got $snap_count)"
    fail=$((fail+1))
fi
assert_grep "snapshot has handover frontmatter" "type: handover" "$handover_arg"
assert_grep "snapshot names HIMMEL-276" "HIMMEL-276" "$handover_arg"
assert_grep "stderr ACTION REQUIRED" "ACTION REQUIRED" "$STDERR_LOG"
assert_grep "stderr RESUME ARMED" "RESUME ARMED" "$STDERR_LOG"
fired=$(count_glob "$S" 'auto-arm-fired-sub-*')
if [ "$fired" = "1" ]; then
    echo "  PASS  fired marker written"
    pass=$((pass+1))
else
    echo "  FAIL  fired marker written (got $fired)"
    fail=$((fail+1))
fi

echo "Test 5: one-shot — second Agent result in same session is a quiet pass"
rm -f "$ARM_LOG"
run_hook "$S" "$(cap_payload 'sid-004')"
assert_rc "post-fire run exits 0 (one-shot held)" 0 $?
assert_file "no second arm call" absent "$ARM_LOG"

echo "Test 6: alternate sentinel 'usage limit reached' — arm fires"
S="$TMP/s6"; mkdir -p "$S"
rm -f "$ARM_LOG"
run_hook "$S" '{"session_id":"sid-006","tool_name":"Agent","tool_response":{"type":"tool_result","content":"Claude usage limit reached. Please try again later."}}'
assert_rc "usage-limit-reached sentinel exits 2" 2 $?
assert_file "arm call logged for alt sentinel" present "$ARM_LOG"
rm -f "$ARM_LOG"

echo "Test 7: legitimate result text DISCUSSING Claude usage limits — no false positive"
S="$TMP/s7"; mkdir -p "$S"
rm -f "$ARM_LOG"
run_hook "$S" '{"session_id":"sid-007","tool_name":"Agent","tool_response":{"type":"tool_result","content":"Research summary: the Claude usage limit on the Pro tier resets every 5 hours; plan capacity accordingly."}}'
assert_rc "discussion of usage limits exits 0 (no spurious block)" 0 $?
assert_file "no arm call for mere mention" absent "$ARM_LOG"
rm -f "$ARM_LOG"

echo "Test 8: case-insensitive sentinel match (UPPERCASE)"
S="$TMP/s8"; mkdir -p "$S"
rm -f "$ARM_LOG"
run_hook "$S" '{"session_id":"sid-008","tool_name":"Agent","tool_response":{"type":"tool_result","content":"YOU HAVE HIT YOUR SESSION LIMIT"}}'
assert_rc "uppercase sentinel exits 2" 2 $?
assert_file "arm call logged for uppercase sentinel" present "$ARM_LOG"
rm -f "$ARM_LOG"

echo "Test 9: content as JSON array (list of content blocks) — sentinel still detected"
S="$TMP/s9"; mkdir -p "$S"
rm -f "$ARM_LOG"
run_hook "$S" '{"session_id":"sid-009","tool_name":"Agent","tool_response":{"type":"tool_result","content":[{"type":"text","text":"You have hit your session limit. Try again after reset."}]}}'
assert_rc "array-content sentinel exits 2" 2 $?
assert_file "arm call logged for array-content sentinel" present "$ARM_LOG"
rm -f "$ARM_LOG"

echo "Test 10: arm already exists (rc=3, dedup) — still a one-shot block"
S="$TMP/s10"; mkdir -p "$S"
rm -f "$ARM_LOG"
run_hook_sid "$S" "sid-010" "You have hit your session limit" 3
assert_rc "already-armed exits 2 (still tells the model)" 2 $?
assert_grep "dedup message says ALREADY armed" "ALREADY armed" "$STDERR_LOG"
fired=$(count_glob "$S" 'auto-arm-fired-sub-*')
if [ "$fired" = "1" ]; then
    echo "  PASS  fired marker written on dedup"
    pass=$((pass+1))
else
    echo "  FAIL  fired marker written on dedup (got $fired)"
    fail=$((fail+1))
fi
rm -f "$ARM_LOG"

echo "Test 11: arm failure (rc=4) — exit 1 (visible, non-blocking), no fired marker"
S="$TMP/s11"; mkdir -p "$S"
H11="$TMP/handovers11"; mkdir -p "$H11"
rm -f "$ARM_LOG"
run_hook_sid "$S" "sid-011" "You have hit your session limit" 4
assert_rc "arm-failed run exits 1 (surfaced, non-blocking)" 1 $?
assert_grep "failure surfaced as MALFUNCTION" "MALFUNCTION" "$STDERR_LOG"
fired=$(count_glob "$S" 'auto-arm-fired-sub-*')
if [ "$fired" = "0" ]; then
    echo "  PASS  no fired marker on arm failure (retry next call)"
    pass=$((pass+1))
else
    echo "  FAIL  no fired marker on arm failure (got $fired)"
    fail=$((fail+1))
fi

echo "Test 12: missing arm-resume binary — exit 1 (MALFUNCTION), snapshot still written"
S="$TMP/s12"; mkdir -p "$S"
rm -f "$ARM_LOG"
printf '%s\n' "$(cap_payload 'sid-012')" | \
    AUTO_ARM_STATE_DIR="$S" \
    AUTO_ARM_BIN="$TMP/no-such-arm.sh" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" >/dev/null 2>"$STDERR_LOG"
assert_rc "missing-arm exits 1 (surfaced)" 1 $?
assert_grep "missing arm surfaced as MALFUNCTION" "MALFUNCTION" "$STDERR_LOG"

echo "Test 13: empty stdin — quiet no-op (not a hook invocation)"
S="$TMP/s13"; mkdir -p "$S"
rm -f "$ARM_LOG"
printf '' | \
    AUTO_ARM_STATE_DIR="$S" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" >/dev/null 2>"$STDERR_LOG"
assert_rc "empty-stdin exits 0" 0 $?
assert_file "no arm call on empty stdin" absent "$ARM_LOG"

echo "Test 14: malformed JSON payload — quiet no-op (fail-open)"
S="$TMP/s14"; mkdir -p "$S"
rm -f "$ARM_LOG"
run_hook "$S" 'not json {'
assert_rc "malformed-json exits 0 (fail-open)" 0 $?
assert_file "no arm call on malformed json" absent "$ARM_LOG"

echo "Test 15: missing py-armor lib — MALFUNCTION exit 1 (non-blocking)"
LIBLESS="$TMP/libless"; mkdir -p "$LIBLESS/hooks"
cp "$HOOK" "$LIBLESS/hooks/"
S="$TMP/s15"; mkdir -p "$S"
rm -f "$ARM_LOG"
printf '%s\n' "$(cap_payload 'sid-015')" | \
    AUTO_ARM_STATE_DIR="$S" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$HANDOVER_TEST_DIR" CLAUDE_PROJECT_DIR="$TMP/no-such-projdir" \
    bash "$LIBLESS/hooks/auto-arm-on-subagent-cap.sh" >/dev/null 2>"$STDERR_LOG"
assert_rc "missing-lib exits 1 (MALFUNCTION, non-blocking)" 1 $?
assert_grep "missing lib surfaced as MALFUNCTION" "MALFUNCTION: cannot source py-armor.sh" "$STDERR_LOG"
assert_file "no arm call with armor lib missing" absent "$ARM_LOG"

echo "Test 16: per-session one-shot — different session under same marker key gets its own block"
S="$TMP/s16"; mkdir -p "$S"
rm -f "$ARM_LOG"
# Session A hits cap and fires
run_hook_sid "$S" "session-alpha" "You have hit your session limit" 0
assert_rc "session A gets the block (exit 2)" 2 $?
rm -f "$ARM_LOG"
# Session A re-fires — held
run_hook_sid "$S" "session-alpha" "You have hit your session limit" 0
assert_rc "session A re-check held (exit 0)" 0 $?
assert_file "no second arm for session A" absent "$ARM_LOG"
# Session B — different id, gets its OWN block
run_hook_sid "$S" "session-beta0" "You have hit your session limit" 3
assert_rc "session B gets its own block (exit 2)" 2 $?
fired=$(count_glob "$S" 'auto-arm-fired-sub-*')
if [ "$fired" = "2" ]; then
    echo "  PASS  distinct fired markers for session A and B"
    pass=$((pass+1))
else
    echo "  FAIL  distinct fired markers for session A and B (got $fired)"
    fail=$((fail+1))
fi

echo "Test 17: handover root unresolvable — snapshot falls back to state dir, arm still proceeds"
S="$TMP/s17"; mkdir -p "$S"
rm -f "$ARM_LOG"
printf '%s\n' "$(cap_payload 'sid-017')" | \
    AUTO_ARM_STATE_DIR="$S" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$TMP/no-such-root" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" >/dev/null 2>"$STDERR_LOG"
assert_rc "fallback run still exits 2 (armed)" 2 $?
assert_file "arm still called on handover fallback" present "$ARM_LOG"
snap_count=$(count_glob "$S" 'auto-arm-status-sub-*.md')
if [ "$snap_count" = "1" ]; then
    echo "  PASS  snapshot fell back to state dir"
    pass=$((pass+1))
else
    echo "  FAIL  snapshot fell back to state dir (got $snap_count)"
    fail=$((fail+1))
fi
rm -f "$ARM_LOG"

echo "Test 18: acceptance scenario (HIMMEL-276) — low usage cache + Agent result carries sentinel"
# This is the EXACT scenario from the ticket: usage cache reads LOW (the
# PreToolUse hook stays silent), but an Agent tool result carries the cap.
# The PostToolUse hook must fire and arm regardless of cache state.
S="$TMP/s18"; mkdir -p "$S"
H18="$TMP/handovers18"; mkdir -p "$H18"
LOW_CACHE="$TMP/c18-low.json"
cat > "$LOW_CACHE" <<'CEOF'
{"five_hour":{"utilization":15,"resets_at":"2026-06-10T13:30:00+00:00"},"seven_day":{"utilization":10,"resets_at":"2026-06-13T09:00:00+00:00"}}
CEOF
rm -f "$ARM_LOG"
printf '%s\n' "$(cap_payload 'sid-018')" | \
    AUTO_ARM_STATE_DIR="$S" AUTO_ARM_CACHE="$LOW_CACHE" \
    AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
    HANDOVER_DIR="$H18" CLAUDE_PROJECT_DIR="" \
    bash "$HOOK" >/dev/null 2>"$STDERR_LOG"
assert_rc "acceptance: subagent-cap arm fires despite low cache (exits 2)" 2 $?
assert_file "acceptance: arm called" present "$ARM_LOG"
snap_count=$(count_glob "$H18" 'auto-arm-status-sub-*.md')
if [ "$snap_count" = "1" ]; then
    echo "  PASS  acceptance: snapshot written to handover root"
    pass=$((pass+1))
else
    echo "  FAIL  acceptance: snapshot written to handover root (got $snap_count)"
    fail=$((fail+1))
fi
# ARM_LOG has the arm arguments; snapshot body has the subagent cause text — check snapshot
# Verify the snapshot content (check via handover_arg)
handover_arg=$(LC_ALL=C sed -E 's/.*--handover ([^ ]+).*/\1/' "$ARM_LOG" | head -1)
assert_grep "acceptance: snapshot frontmatter type" "type: handover" "$handover_arg"
assert_grep "acceptance: snapshot credits HIMMEL-276" "HIMMEL-276" "$handover_arg"
rm -f "$ARM_LOG"

echo "Test 19: sentinel inside double quotes — no false positive (HIMMEL-294)"
# A subagent reviewing hook docs may quote the sentinel string.
# The text below DISCUSSES the sentinel but the sentinel itself is double-quoted.
S="$TMP/s19"; mkdir -p "$S"
rm -f "$ARM_LOG"
run_hook "$S" '{"session_id":"sid-019","tool_name":"Agent","tool_response":{"type":"tool_result","content":"The hook fires on \"You have hit your session limit\" in the result text."}}'
assert_rc "double-quoted sentinel exits 0 (no false positive)" 0 $?
assert_file "no arm call for double-quoted sentinel" absent "$ARM_LOG"

echo "Test 20: sentinel inside backticks — no false positive (HIMMEL-294)"
# Use printf to embed real backtick chars in the JSON (single-quote \` is not
# a valid JSON escape and would cause a parse-error SKIP, masking the bug).
S="$TMP/s20"; mkdir -p "$S"
rm -f "$ARM_LOG"
# shellcheck disable=SC2016  # literal backticks inside the JSON payload — no expansion wanted
run_hook "$S" "$(printf '{"session_id":"sid-020","tool_name":"Agent","tool_response":{"type":"tool_result","content":"Detection sentinels: `You have hit your session limit` and `usage limit reached`"}}')"
assert_rc "backtick-quoted sentinel exits 0 (no false positive)" 0 $?
assert_file "no arm call for backtick-quoted sentinel" absent "$ARM_LOG"

echo "Test 21: genuine unquoted sentinel — still fires (HIMMEL-294 regression guard)"
S="$TMP/s21"; mkdir -p "$S"
rm -f "$ARM_LOG"
run_hook "$S" '{"session_id":"sid-021","tool_name":"Agent","tool_response":{"type":"tool_result","content":"You have hit your session limit. Please try again after the reset."}}'
assert_rc "genuine unquoted sentinel exits 2 (arm fires)" 2 $?
assert_file "arm call logged for genuine sentinel" present "$ARM_LOG"
rm -f "$ARM_LOG"

echo "Test 22: snapshot path resolves via HANDOVER_DIR (not cwd), even from a different cwd (HIMMEL-294)"
# Verify that with HANDOVER_DIR set, the snapshot always lands in the
# supplied directory regardless of what the session cwd is at hook runtime.
# This is the Mode B path; Mode A is covered by the handover-path resolver
# itself (which uses hook_dir-relative git rev-parse after this fix).
S="$TMP/s22"; mkdir -p "$S"
FAKE_CWD="$TMP/fake-worktree-cwd"; mkdir -p "$FAKE_CWD"
# A handovers/ dir here should NOT attract the snapshot — hook must use HANDOVER_DIR.
mkdir -p "$FAKE_CWD/handovers"
H22="$TMP/handovers22"; mkdir -p "$H22"
rm -f "$ARM_LOG"
(
    cd "$FAKE_CWD" || exit 1
    printf '%s\n' "$(cap_payload 'sid-022')" | \
        AUTO_ARM_STATE_DIR="$S" \
        AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
        HANDOVER_DIR="$H22" CLAUDE_PROJECT_DIR="" \
        bash "$HOOK" >/dev/null 2>"$STDERR_LOG"
)
assert_rc "worktree-cwd run exits 2 (arm fires)" 2 $?
snap_count_correct=$(count_glob "$H22" 'auto-arm-status-sub-*.md')
snap_count_wrong=$(count_glob "$FAKE_CWD/handovers" 'auto-arm-status-sub-*.md')
if [ "$snap_count_correct" = "1" ]; then
    echo "  PASS  snapshot written to HANDOVER_DIR (not cwd/handovers)"
    pass=$((pass+1))
else
    echo "  FAIL  snapshot written to HANDOVER_DIR (got $snap_count_correct in correct dir)"
    fail=$((fail+1))
fi
if [ "$snap_count_wrong" = "0" ]; then
    echo "  PASS  no snapshot in fake cwd/handovers"
    pass=$((pass+1))
else
    echo "  FAIL  no snapshot in fake cwd/handovers (got $snap_count_wrong — cwd-leak bug active)"
    fail=$((fail+1))
fi
rm -f "$ARM_LOG"

echo "Test 23: Mode A snapshot resolves via hook_dir git root, not session cwd (HIMMEL-294)"
# Create a fake worktree-like git repo with a handovers/ dir as the session cwd.
# No HANDOVER_DIR set. The hook must use handover_root from hook_dir's git root,
# not the session cwd. The real repo containing the hook (scripts/hooks/) has a
# handovers/ dir (present in this checkout); the fake cwd repo must NOT attract
# the snapshot.
S="$TMP/s23"; mkdir -p "$S"
FAKE_REPO="$TMP/fake-git-repo"; mkdir -p "$FAKE_REPO"
git init -q "$FAKE_REPO" 2>/dev/null || true
mkdir -p "$FAKE_REPO/handovers"
rm -f "$ARM_LOG"
# hook_dir is the scripts/hooks dir in the real worktree checkout (where $HOOK lives).
# That real checkout's git root has a handovers/ dir; the hook should write there.
REAL_HOOK_GIT_ROOT="$(git -C "$(dirname "$HOOK")" rev-parse --show-toplevel 2>/dev/null || echo "")"
REAL_HANDOVERS="$REAL_HOOK_GIT_ROOT/handovers"
(
    cd "$FAKE_REPO" || exit 1
    printf '%s\n' "$(cap_payload 'sid-023')" | \
        AUTO_ARM_STATE_DIR="$S" \
        AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$ARM_LOG" \
        CLAUDE_PROJECT_DIR="" \
        bash "$HOOK" >/dev/null 2>"$STDERR_LOG"
)
# rc may be 2 (armed) or 0/1 if handovers dir was unresolvable; we only assert
# snapshot NOT in fake-repo/handovers (the cwd-leak direction).
fake_snap_count=$(count_glob "$FAKE_REPO/handovers" 'auto-arm-status-sub-*.md')
if [ "$fake_snap_count" = "0" ]; then
    echo "  PASS  no snapshot leaked into fake cwd repo handovers (Mode A cwd-fix)"
    pass=$((pass+1))
else
    echo "  FAIL  snapshot leaked into fake cwd repo handovers — cwd bug still active (got $fake_snap_count)"
    fail=$((fail+1))
fi
# If real handovers/ exists, also verify it landed there.
if [ -n "$REAL_HANDOVERS" ] && [ -d "$REAL_HANDOVERS" ]; then
    real_snap_count=$(count_glob "$REAL_HANDOVERS" 'auto-arm-status-sub-sid-023*.md')
    if [ "$real_snap_count" = "1" ]; then
        echo "  PASS  snapshot landed in real hook repo handovers (Mode A path correct)"
        pass=$((pass+1))
    else
        echo "  FAIL  snapshot not found in real hook repo handovers (got $real_snap_count in $REAL_HANDOVERS)"
        fail=$((fail+1))
    fi
    # Cleanup the snapshot we just wrote into the actual repo handovers dir
    rm -f "$REAL_HANDOVERS"/auto-arm-status-sub-sid-023*.md 2>/dev/null || true
fi
rm -f "$ARM_LOG"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
