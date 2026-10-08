#!/usr/bin/env bash
# Test for scripts/hooks/memory-bash-line-check.sh (HIMMEL-4891): a Bash write
# to the auto-memory MEMORY.md (heredoc, sed -i, tee, printf >>) bypasses
# guard-memory-capture.sh, so the PostToolUse hook re-checks the file.
# Usage: bash scripts/hooks/test-memory-bash-line-check.sh
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/memory-bash-line-check.sh"
FAILED=0
SB="$(mktemp -d "${TMPDIR:-/tmp}/memory-bash-line-check.XXXXXX")" || exit 1; trap 'rm -rf "$SB"' EXIT
export HOME="$SB"   # hermetic: never touches the real auto-memory
MEM="$SB/.claude/projects/proj/memory"; mkdir -p "$MEM"
IDX="$MEM/MEMORY.md"

assert_rc() {
    if [ "$3" = "$2" ]; then echo "PASS $1 (rc=$3)"
    else echo "FAIL $1 (expected rc=$2, got $3)"; FAILED=1; fi
}

repeat_char() {
    local s="$1" n="$2" i=0 out=""
    while [ "$i" -lt "$n" ]; do out="$out$s"; i=$((i + 1)); done
    printf '%s' "$out"
}

run() { # $1=tool $2=command
    jq -nc --arg t "$1" --arg c "$2" \
      '{tool_name:$t,hook_event_name:"PostToolUse",tool_input:{command:$c}}' | bash "$HOOK" 2>"$SB/err" >/dev/null
}

cmd="cat >> $IDX <<'EOF'"
ok200="- $(repeat_char x 198)"
long250="- $(repeat_char x 248)"

# 1: heredoc append of a 250-char line is flagged, naming the line.
printf -- '- short\n%s\n' "$long250" > "$IDX"
run Bash "$cmd"; assert_rc "250-char heredoc line flagged" 2 "$?"
if grep -q 'line 2' "$SB/err"; then echo "PASS names line 2"; else echo "FAIL stderr does not name line 2"; FAILED=1; fi

# 2: exactly-200-char line passes.
printf -- '- short\n%s\n' "$ok200" > "$IDX"
run Bash "$cmd"; assert_rc "200-char line passes" 0 "$?"

# 3: command that does not name MEMORY.md is ignored even with a bad index.
printf -- '%s\n' "$long250" > "$IDX"
run Bash "echo hi"; assert_rc "unrelated command ignored" 0 "$?"

# 4: a MEMORY.md outside the auto-memory store is ignored.
mkdir -p "$SB/other"; printf -- '%s\n' "$long250" > "$SB/other/MEMORY.md"
run Bash "cat >> $SB/other/MEMORY.md <<'EOF'"; assert_rc "non-auto-memory MEMORY.md ignored" 0 "$?"

# 5: non-Bash tool ignored.
run Edit "$cmd"; assert_rc "non-Bash tool ignored" 0 "$?"

# 6: MEMORY_LINE_MAX knob is honoured (shared with the guard).
printf -- '%s\n' "$ok200" > "$IDX"
MEMORY_LINE_MAX=100 run Bash "$cmd"; assert_rc "MEMORY_LINE_MAX=100 flags a 200-char line" 2 "$?"

# 7: MEMORY_CAPTURE_OK=1 bypass.
printf -- '%s\n' "$long250" > "$IDX"
MEMORY_CAPTURE_OK=1 run Bash "$cmd"; assert_rc "MEMORY_CAPTURE_OK=1 bypass" 0 "$?"

# 8: missing index file is a silent allow.
rm -f "$IDX"
run Bash "$cmd"; assert_rc "missing index allowed" 0 "$?"

exit "$FAILED"
