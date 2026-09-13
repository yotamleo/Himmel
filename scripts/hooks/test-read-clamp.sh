#!/usr/bin/env bash
# test-read-clamp.sh — house-style test harness for read-clamp.sh (HIMMEL-2993).
# Platform guard: bash-only, no .ps1 twin -- exercises the bash-only hook above.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/read-clamp.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

FAILED=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

RUNTIME_DIR="$WORK/xdg-runtime"
mkdir -p "$RUNTIME_DIR"

SMALL_FILE="$WORK/small.txt"
BIG_FILE="$WORK/big.txt"
seq 1 3 > "$SMALL_FILE"
seq 1 10 > "$BIG_FILE"

LINES_ENV="HIMMEL_READ_CLAMP_LINES=5"

run_case() {  # $1 = json, $2 = extra env assigns (space-separated VAR=val), $3 = xdg runtime dir override
    local json="$1" extra_env="${2:-}" runtime="${3:-$RUNTIME_DIR}"
    # shellcheck disable=SC2086 # intentional word-splitting: LINES_ENV/extra_env carry space-separated VAR=val assignments for env
    printf '%s' "$json" | env $LINES_ENV XDG_RUNTIME_DIR="$runtime" $extra_env bash "$HOOK" >"$WORK/stdout" 2>"$WORK/stderr"
    echo "$?"
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        echo "  stderr: $(cat "$WORK/stderr" 2>/dev/null)"
        FAILED=$((FAILED + 1))
    fi
}

assert_stderr_contains() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$WORK/stderr" 2>/dev/null; then
        echo "PASS $label (stderr contains \"$needle\")"
    else
        echo "FAIL $label — stderr did not contain \"$needle\": $(cat "$WORK/stderr" 2>/dev/null)"
        FAILED=$((FAILED + 1))
    fi
}

j_read() {  # $1 = path, $2 = session_id
    printf '{"tool_name":"Read","tool_input":{"file_path":%s},"session_id":%s}' \
        "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)"
}

j_read_ranged() {  # $1 = path, $2 = offset, $3 = limit, $4 = session_id
    printf '{"tool_name":"Read","tool_input":{"file_path":%s,"offset":%s,"limit":%s},"session_id":%s}' \
        "$(printf '%s' "$1" | jq -Rs .)" "$2" "$3" "$(printf '%s' "$4" | jq -Rs .)"
}

j_bash() {  # $1 = command, $2 = session_id
    printf '{"tool_name":"Bash","tool_input":{"command":%s},"session_id":%s}' \
        "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)"
}

echo "=== read-clamp.sh test suite ==="

# 1. gate off -> allow, even for a whole-file read of a big file.
rc=$(run_case "$(j_read "$BIG_FILE" sess-gate)" "HIMMEL_CONSOLE_LEG=0")
assert_rc "gate off allows whole-file read" 0 "$rc"

# 2. whole-file read > N lines -> deny with line-count + range-shape message.
rc=$(run_case "$(j_read "$BIG_FILE" sess-wholefile)" "HIMMEL_CONSOLE_LEG=1")
assert_rc "whole-file read over limit denies" 2 "$rc"
assert_stderr_contains "whole-file deny names line count" "10 lines"
assert_stderr_contains "whole-file deny names range shape" "offset=<n> limit=<m>"

# 3. whole-file read <= N lines -> allow.
rc=$(run_case "$(j_read "$SMALL_FILE" sess-smallfile)" "HIMMEL_CONSOLE_LEG=1")
assert_rc "whole-file read under limit allows" 0 "$rc"

# 4. ranged read -> allow + recorded.
rc=$(run_case "$(j_read_ranged "$BIG_FILE" 1 5 sess-range)" "HIMMEL_CONSOLE_LEG=1")
assert_rc "ranged read allows" 0 "$rc"
STATE_FILE="$RUNTIME_DIR/himmel-read-clamp/sess-range/reads.tsv"
if [ -f "$STATE_FILE" ] && grep -qF "$(printf '%s\t1\t5' "$BIG_FILE")" "$STATE_FILE"; then
    echo "PASS ranged read recorded in state"
else
    echo "FAIL ranged read recorded in state — state file: $(cat "$STATE_FILE" 2>/dev/null || echo MISSING)"
    FAILED=$((FAILED + 1))
fi

# 5. identical repeat of the same (path, offset, limit) -> deny.
rc=$(run_case "$(j_read_ranged "$BIG_FILE" 1 5 sess-range)" "HIMMEL_CONSOLE_LEG=1")
assert_rc "identical repeat read denies" 2 "$rc"
assert_stderr_contains "repeat deny names 'already read'" "already read"

# 6. a different range of the same file -> allow.
rc=$(run_case "$(j_read_ranged "$BIG_FILE" 6 5 sess-range)" "HIMMEL_CONSOLE_LEG=1")
assert_rc "different range of same file allows" 0 "$rc"

# 7. Bash cat of a big file -> deny with the same message.
rc=$(run_case "$(j_bash "cat $BIG_FILE" sess-bash-cat)" "HIMMEL_CONSOLE_LEG=1")
assert_rc "bash cat over limit denies" 2 "$rc"
assert_stderr_contains "bash cat deny names line count" "10 lines"

# 8. an unrecognised Bash shape -> allow (never deny on a guess).
rc=$(run_case "$(j_bash "cat $BIG_FILE | wc -l" sess-bash-unrec)" "HIMMEL_CONSOLE_LEG=1")
assert_rc "unrecognised bash shape allows" 0 "$rc"

# 9. missing/uncreatable runtime dir -> allow (fail-open on state).
rc=$(run_case "$(j_read "$BIG_FILE" sess-noruntime)" "HIMMEL_CONSOLE_LEG=1" "/nonexistent-root-xyz-himmel-2993")
assert_rc "missing runtime dir allows" 0 "$rc"

# 10. escape hatch HIMMEL_READ_CLAMP_OK=1 -> allow, logged to stderr.
rc=$(run_case "$(j_read "$BIG_FILE" sess-escape)" "HIMMEL_CONSOLE_LEG=1 HIMMEL_READ_CLAMP_OK=1")
assert_rc "escape env allows" 0 "$rc"
assert_stderr_contains "escape env logs bypass" "HIMMEL_READ_CLAMP_OK=1"

echo "==============================="
if [ "$FAILED" -eq 0 ]; then
    echo "All cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
