#!/usr/bin/env bash
# Hermetic smoke test for scripts/hooks/telegram-notification.sh (HIMMEL-1250).
#
# Builds a throwaway git repo, drives the hook in CHILD MODE
# (`__himmel_detached <payload-file>`) with a stub `bun` on PATH, and asserts:
# (1) TELEGRAM_GROUP_CHAT_ID unset -> silent no-op, bun never invoked;
# (2) TELEGRAM_GROUP_CHAT_ID set -> bun invoked with the "notification" arg +
# the composed TG_* env; (3) a salus-named repo still relays a status but
# NEVER forwards the notification message text.
#
# Usage: bash scripts/hooks/test-telegram-notification.sh
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOK_DIR/telegram-notification.sh"

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
    printf 'TG_NOTIFICATION_TYPE=%s\n' "\${TG_NOTIFICATION_TYPE:-}"
    printf 'TG_MESSAGE=%s\n' "\${TG_MESSAGE:-}"
} >> "$BUN_ARGS"
exit 0
EOF
chmod +x "$STUB_DIR/bun"

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

    CASE_PAYLOAD="$(printf '{"cwd":"%s","notification_type":"permission_prompt","message":"Bash(rm -rf tmp) needs approval"}' "$CASE_REPO")"
}

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

# 2. Set TELEGRAM_GROUP_CHAT_ID -> bun invoked with notification + composed env.
build_case "himmel"
run_hook "-1001234" 5
if [ -f "$BUN_LOG" ] && [ "$(grep -c . "$BUN_LOG")" = "1" ]; then pass "set chat id: bun invoked exactly once"; else fail "set chat id: bun invoked exactly once"; fi
if grep -q 'ARGS=run .*session-status\.ts notification' "$BUN_ARGS" 2>/dev/null; then
    pass "bun invoked with the 'notification' arg"
else
    fail "bun invoked with the 'notification' arg (got: $(cat "$BUN_ARGS" 2>/dev/null))"
fi
if grep -q '^TG_NOTIFICATION_TYPE=permission_prompt$' "$BUN_ARGS" 2>/dev/null; then pass "TG_NOTIFICATION_TYPE passed through"; else fail "TG_NOTIFICATION_TYPE passed through"; fi
if grep -q '^TG_MESSAGE=Bash(rm -rf tmp) needs approval$' "$BUN_ARGS" 2>/dev/null; then
    pass "TG_MESSAGE passed through"
else
    fail "TG_MESSAGE passed through (got: $(cat "$BUN_ARGS" 2>/dev/null))"
fi

# 3. Salus-named repo -> TG_MESSAGE cleared (never forwards notification text),
#    but the status still relays.
build_case "salus-vault"
run_hook "-1001234" 5
if [ -f "$BUN_LOG" ]; then pass "salus repo: bun still invoked (status still relays, redacted downstream)"; else fail "salus repo: bun still invoked"; fi
if grep -q '^TG_MESSAGE=$' "$BUN_ARGS" 2>/dev/null; then
    pass "salus repo: TG_MESSAGE cleared (notification text never forwarded)"
else
    fail "salus repo: TG_MESSAGE cleared (got: $(cat "$BUN_ARGS" 2>/dev/null))"
fi

echo "---"
echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" -eq 0 ]
