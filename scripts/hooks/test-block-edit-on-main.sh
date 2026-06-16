#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-edit-on-main.sh.
#
# Usage: bash scripts/hooks/test-block-edit-on-main.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/block-edit-on-main.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

# Run the hook with the given JSON on stdin + env, capture exit code only.
run_case() {
    local input="$1"
    local env_assign="$2"
    if [ -n "$env_assign" ]; then
        printf '%s' "$input" | env "$env_assign" CLAUDE_PROJECT_DIR="$PROJDIR" bash "$HOOK" >/dev/null 2>&1
    else
        printf '%s' "$input" | env CLAUDE_PROJECT_DIR="$PROJDIR" bash "$HOOK" >/dev/null 2>&1
    fi
    echo "$?"
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

# Need a real-looking primary; the script's own primary works.
PROJDIR=$(git rev-parse --show-toplevel 2>/dev/null)
# If we're already inside a worktree (common when running this from a
# feat/* branch), walk to the actual primary.
if PRIMARY_CANDIDATE=$(git rev-parse --git-common-dir 2>/dev/null); then
    PROJDIR=$(cd "$(dirname "$PRIMARY_CANDIDATE")" && pwd)
fi

FAILED=0

# T1: traversal worktrees/../foo.sh should BLOCK (rc=2)
rc=$(run_case "{\"tool_input\":{\"file_path\":\"$PROJDIR/.claude/worktrees/../foo.sh\"}}" "")
assert_rc "T1 worktrees/.. traversal" 2 "$rc"

# T2: traversal handovers/../scripts/foo.sh should BLOCK (rc=2)
rc=$(run_case "{\"tool_input\":{\"file_path\":\"$PROJDIR/handovers/../scripts/foo.sh\"}}" "")
assert_rc "T2 handovers/.. traversal" 2 "$rc"

# T3: trailing slash on CLAUDE_PROJECT_DIR should still BLOCK (rc=2)
rc=$(printf '%s' "{\"tool_input\":{\"file_path\":\"$PROJDIR/scripts/foo.sh\"}}" | CLAUDE_PROJECT_DIR="$PROJDIR/" bash "$HOOK" >/dev/null 2>&1; echo "$?")
assert_rc "T3 trailing slash on PROJDIR" 2 "$rc"

# T4: bypass set + primary edit should ALLOW silently (rc=0)
rc=$(run_case "{\"tool_input\":{\"file_path\":\"$PROJDIR/scripts/foo.sh\"}}" "EDIT_ON_MAIN_OK=1")
assert_rc "T4 bypass set" 0 "$rc"

# T4b: bypass produces ZERO stderr
stderr_bytes=$(printf '%s' "{\"tool_input\":{\"file_path\":\"$PROJDIR/scripts/foo.sh\"}}" | EDIT_ON_MAIN_OK=1 CLAUDE_PROJECT_DIR="$PROJDIR" bash "$HOOK" 2>&1 >/dev/null | wc -c)
assert_rc "T4b bypass silent stderr" 0 "$stderr_bytes"

# T5: legitimate worktree edit should ALLOW (rc=0)
WT_PATH="$PROJDIR/.claude/worktrees/feat+infra-b1-b2/scripts/foo.sh"
rc=$(run_case "{\"tool_input\":{\"file_path\":\"$WT_PATH\"}}" "")
assert_rc "T5 worktree edit" 0 "$rc"

# T6: handover edit on main should ALLOW (rc=0)
rc=$(run_case "{\"tool_input\":{\"file_path\":\"$PROJDIR/handovers/yotam/status.md\"}}" "")
assert_rc "T6 handover edit" 0 "$rc"

# T7: plain primary edit on main should BLOCK (rc=2)
rc=$(run_case "{\"tool_input\":{\"file_path\":\"$PROJDIR/scripts/foo.sh\"}}" "")
assert_rc "T7 plain primary edit" 2 "$rc"

# T8: outside project should ALLOW (rc=0)
rc=$(run_case "{\"tool_input\":{\"file_path\":\"/tmp/foo.sh\"}}" "")
assert_rc "T8 outside project" 0 "$rc"

# T9: NotebookEdit uses notebook_path
rc=$(run_case "{\"tool_input\":{\"notebook_path\":\"$PROJDIR/x.ipynb\"}}" "")
assert_rc "T9 NotebookEdit blocked" 2 "$rc"

# T10: missing file_path should ALLOW silently (rc=0)
rc=$(run_case '{"tool_input":{}}' "")
assert_rc "T10 missing file_path" 0 "$rc"

# --- Cross-canonicaliser coverage (python branch was silently broken
# in round-2 — `python -c '...' -- "$1"` made sys.argv[1]=="--" instead
# of the path). Force CANON_FORCE=python3 to exercise the fallback branch
# end-to-end. Skip if python3 not available on the runner.
if command -v python3 >/dev/null 2>&1; then
    rc=$(printf '%s' "{\"tool_input\":{\"file_path\":\"$PROJDIR/.claude/worktrees/../foo.sh\"}}" | CANON_FORCE=python3 CLAUDE_PROJECT_DIR="$PROJDIR" bash "$HOOK" >/dev/null 2>&1; echo "$?")
    assert_rc "T11 python3 branch — traversal block" 2 "$rc"

    rc=$(printf '%s' "{\"tool_input\":{\"file_path\":\"$PROJDIR/.claude/worktrees/feat+infra-b1-b2/scripts/foo.sh\"}}" | CANON_FORCE=python3 CLAUDE_PROJECT_DIR="$PROJDIR" bash "$HOOK" >/dev/null 2>&1; echo "$?")
    assert_rc "T12 python3 branch — worktree allow" 0 "$rc"

    rc=$(printf '%s' "{\"tool_input\":{\"file_path\":\"$PROJDIR/scripts/foo.sh\"}}" | CANON_FORCE=python3 CLAUDE_PROJECT_DIR="$PROJDIR" bash "$HOOK" >/dev/null 2>&1; echo "$?")
    assert_rc "T13 python3 branch — primary block" 2 "$rc"
else
    echo "SKIP T11-T13 (no python3 on PATH)"
fi

# --- Fail-CLOSED coverage. CANON_FORCE to an unknown mode triggers the
# `*) return 1` arm of canon(), proj_real ends up empty, and the empty-
# check arm should exit 2 with the actionable message.
rc=$(printf '%s' "{\"tool_input\":{\"file_path\":\"$PROJDIR/scripts/foo.sh\"}}" | CANON_FORCE=does-not-exist CLAUDE_PROJECT_DIR="$PROJDIR" bash "$HOOK" >/dev/null 2>&1; echo "$?")
assert_rc "T14 unknown CANON_MODE — fail closed" 2 "$rc"

# --- Wedged-stub coverage (HIMMEL-249). A python3 that wedges (ignores
# TERM) must read as a fail-CLOSED block (rc=2 via empty canon output),
# bounded by the armor — never a hung hook hanging the whole session.
if timeout --version 2>/dev/null | grep -qi coreutils; then
    WEDGE_BIN=$(mktemp -d)
    cat > "$WEDGE_BIN/python3" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep 30
EOF
    chmod +x "$WEDGE_BIN/python3"
    start=$(date +%s)
    rc=$(printf '%s' "{\"tool_input\":{\"file_path\":\"$PROJDIR/scripts/foo.sh\"}}" \
        | PATH="$WEDGE_BIN:$PATH" PY_ARMOR_TIMEOUT=1 PY_ARMOR_KILL_AFTER=1 \
          CANON_FORCE=python3 CLAUDE_PROJECT_DIR="$PROJDIR" bash "$HOOK" >/dev/null 2>&1; echo "$?")
    elapsed=$(( $(date +%s) - start ))
    assert_rc "T15 wedged python3 stub fails closed" 2 "$rc"
    if [ "$elapsed" -lt 15 ]; then
        echo "PASS T15 bounded (${elapsed}s)"
    else
        echo "FAIL T15 bounded — took ${elapsed}s"
        FAILED=$((FAILED + 1))
    fi
    rm -rf "$WEDGE_BIN" 2>/dev/null || true
else
    echo "SKIP T15 (no GNU coreutils timeout on this runner)"
fi

# --- Missing py-armor lib (HIMMEL-249 CR). An unguarded source under
# set -e would exit rc=1, which PreToolUse does NOT block on — the hook
# would fail OPEN. Copy the hook into a tree that has guardrails/lib.sh
# but NO lib/py-armor.sh: it must fail CLOSED (rc=2 + refusal message).
LIBLESS=$(mktemp -d)
mkdir -p "$LIBLESS/hooks" "$LIBLESS/guardrails"
cp "$HOOK" "$LIBLESS/hooks/"
cp "$(dirname "$HOOK")/../guardrails/lib.sh" "$LIBLESS/guardrails/"
err=$(printf '%s' "{\"tool_input\":{\"file_path\":\"$PROJDIR/scripts/foo.sh\"}}" | CLAUDE_PROJECT_DIR="$PROJDIR" bash "$LIBLESS/hooks/block-edit-on-main.sh" 2>&1 >/dev/null); rc=$?
assert_rc "T16 missing py-armor lib fails closed" 2 "$rc"
case "$err" in
    *"cannot source py-armor.sh"*) echo "PASS T16 refusal message" ;;
    *) echo "FAIL T16 refusal message — got: $err"; FAILED=$((FAILED + 1)) ;;
esac
rm -rf "$LIBLESS" 2>/dev/null || true

# --- Missing guardrails/lib.sh (issue #323). An unguarded source under
# set -e exits rc=1, which PreToolUse does NOT block on — fail OPEN.
# The guard must produce rc=2 + a recognisable message (fail CLOSED).
GUARDRAILLESS=$(mktemp -d)
mkdir -p "$GUARDRAILLESS/hooks" "$GUARDRAILLESS/lib"
cp "$HOOK" "$GUARDRAILLESS/hooks/"
cp "$(dirname "$HOOK")/../lib/py-armor.sh" "$GUARDRAILLESS/lib/" 2>/dev/null || true
err=$(printf '%s' "{\"tool_input\":{\"file_path\":\"$PROJDIR/scripts/foo.sh\"}}" | CLAUDE_PROJECT_DIR="$PROJDIR" bash "$GUARDRAILLESS/hooks/block-edit-on-main.sh" 2>&1 >/dev/null); rc=$?
assert_rc "T17 missing guardrails lib fails closed" 2 "$rc"
case "$err" in
    *"cannot source guardrails/lib.sh"*) echo "PASS T17 refusal message" ;;
    *) echo "FAIL T17 refusal message — got: $err"; FAILED=$((FAILED + 1)) ;;
esac
rm -rf "$GUARDRAILLESS" 2>/dev/null || true

# --- T7 env-dep note. T7 only blocks if the runner's primary repo HEAD is
# actually `main`. Surface a clear SKIP if it isn't, so the test passing
# on a non-main runner doesn't mask a regression.
primary_head=$(git -C "$PROJDIR" symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ "$primary_head" != "main" ]; then
    echo "WARN T7 — primary HEAD is '$primary_head' (not 'main'); T7 passed via the branch-check short-circuit, NOT the block path. Re-run on a runner with primary on main to exercise it."
fi

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
