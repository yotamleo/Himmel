#!/usr/bin/env bash
# Hermetic smoke test for scripts/hooks/telegram-session-end.sh (HIMMEL-1250).
#
# Builds a throwaway git repo + transcript, drives the hook in CHILD MODE
# (`__himmel_detached <payload-file>`, same seam test-jira-nudge-on-end.sh
# uses) with a stub `bun` on PATH, and asserts: (1) TELEGRAM_GROUP_CHAT_ID
# unset -> silent no-op, bun never invoked; (2) TELEGRAM_GROUP_CHAT_ID set ->
# bun invoked with the "sessionend" arg + the composed TG_* env, including the
# transcript-extracted last-assistant text; (3) a salus-named repo still
# relays a status but NEVER forwards transcript content (TG_LAST_ASSISTANT
# stays empty — the guard trips before extraction, not after).
#
# The detach primitive itself (setsid/disown branches) is covered by
# scripts/lib/test-detach.sh; this test only asserts the hook's own contract.
#
# Usage: bash scripts/hooks/test-telegram-session-end.sh
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOK_DIR/telegram-session-end.sh"

FAILED=0
PASSED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "$ROOT_TMP"' EXIT

STUB_DIR="$ROOT_TMP/stubs"
mkdir -p "$STUB_DIR"
BUN_LOG="$ROOT_TMP/bun-invocations.log"
BUN_ARGS="$ROOT_TMP/bun-args.log"
cat > "$STUB_DIR/bun" <<EOF
#!/usr/bin/env bash
echo called >> "$BUN_LOG"
{
    printf 'ARGS=%s\n' "\$*"
    printf 'TG_REPO_NAME=%s\n' "\${TG_REPO_NAME:-}"
    printf 'TG_BRANCH=%s\n' "\${TG_BRANCH:-}"
    printf 'TG_LAST_ASSISTANT=%s\n' "\${TG_LAST_ASSISTANT:-}"
} >> "$BUN_ARGS"
exit 0
EOF
chmod +x "$STUB_DIR/bun"

# ---- case builder -----------------------------------------------------------
# Globals set by build_case: CASE_REPO, CASE_PAYLOAD
build_case() {
    # args: <repo_name>
    local name="$1"
    CASE_REPO="$(mktemp -d "$ROOT_TMP/${name}.XXXXXX")"
    git -C "$CASE_REPO" init -q
    git -C "$CASE_REPO" config core.hooksPath /dev/null
    git -C "$CASE_REPO" config commit.gpgsign false
    git -C "$CASE_REPO" config user.email t@t.t
    git -C "$CASE_REPO" config user.name tester
    git -C "$CASE_REPO" remote add origin "https://github.com/acme/${name}.git"
    echo x > "$CASE_REPO/f.txt"
    git -C "$CASE_REPO" add f.txt
    git -C "$CASE_REPO" commit -q --no-verify -m init

    local tx="$CASE_REPO/transcript.jsonl"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Implemented the feature."}]}}\n' > "$tx"

    CASE_PAYLOAD="$(printf '{"cwd":"%s","transcript_path":"%s","reason":"other"}' "$CASE_REPO" "$tx")"
}

# ---- run helper --------------------------------------------------------------
# run_hook <chat_id or empty> <wait_secs> — drives child mode, waits up to
# <wait_secs> for the detached relay to fire (or gives up).
run_hook() {
    local chat_id="$1" wait_secs="$2"
    rm -f "$BUN_LOG" "$BUN_ARGS"
    local pf
    pf="$(mktemp "$ROOT_TMP/payload.XXXXXX")"
    printf '%s' "$CASE_PAYLOAD" > "$pf"
    if [ -n "$chat_id" ]; then
        env PATH="$STUB_DIR:$PATH" TELEGRAM_GROUP_CHAT_ID="$chat_id" \
            bash "$HOOK" __himmel_detached "$pf" >/dev/null 2>&1
    else
        env -u TELEGRAM_GROUP_CHAT_ID PATH="$STUB_DIR:$PATH" \
            bash "$HOOK" __himmel_detached "$pf" >/dev/null 2>&1
    fi
    local w=0
    while [ ! -f "$BUN_LOG" ] && [ "$w" -lt "$wait_secs" ]; do sleep 1; w=$((w + 1)); done
}

# 1. Unset TELEGRAM_GROUP_CHAT_ID -> silent no-op, bun never invoked.
build_case "himmel"
run_hook "" 2
if [ ! -f "$BUN_LOG" ]; then pass "unset chat id: bun never invoked (silent no-op)"; else fail "unset chat id: bun never invoked (silent no-op)"; fi

# 2. Set TELEGRAM_GROUP_CHAT_ID -> bun invoked with sessionend + composed env.
build_case "himmel"
run_hook "-1001234" 5
if [ -f "$BUN_LOG" ] && [ "$(grep -c . "$BUN_LOG")" = "1" ]; then pass "set chat id: bun invoked exactly once"; else fail "set chat id: bun invoked exactly once"; fi
if grep -q 'ARGS=run .*session-status\.ts sessionend' "$BUN_ARGS" 2>/dev/null; then
    pass "bun invoked with the 'sessionend' arg"
else
    fail "bun invoked with the 'sessionend' arg (got: $(cat "$BUN_ARGS" 2>/dev/null))"
fi
if grep -q '^TG_REPO_NAME=himmel$' "$BUN_ARGS" 2>/dev/null; then pass "TG_REPO_NAME passed through"; else fail "TG_REPO_NAME passed through"; fi
if grep -q '^TG_LAST_ASSISTANT=Implemented the feature\.$' "$BUN_ARGS" 2>/dev/null; then
    pass "TG_LAST_ASSISTANT extracted from the transcript"
else
    fail "TG_LAST_ASSISTANT extracted from the transcript (got: $(cat "$BUN_ARGS" 2>/dev/null))"
fi

# 3. Salus-named repo -> TG_LAST_ASSISTANT stays empty (never reads transcript
#    content), but the status still relays (redaction happens downstream, not
#    by silently dropping the whole session-end status).
build_case "salus-vault"
run_hook "-1001234" 5
if [ -f "$BUN_LOG" ]; then pass "salus repo: bun still invoked (status still relays, redacted downstream)"; else fail "salus repo: bun still invoked"; fi
if grep -q '^TG_LAST_ASSISTANT=$' "$BUN_ARGS" 2>/dev/null; then
    pass "salus repo: TG_LAST_ASSISTANT never populated (transcript content never read)"
else
    fail "salus repo: TG_LAST_ASSISTANT never populated (got: $(cat "$BUN_ARGS" 2>/dev/null))"
fi

echo "---"
echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" -eq 0 ]
