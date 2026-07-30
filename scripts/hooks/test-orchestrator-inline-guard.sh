#!/usr/bin/env bash
# Smoke tests for scripts/hooks/orchestrator-inline-guard.sh (HIMMEL-1384 phase 1).
#
# Isolates the fire-log via ORCH_GUARD_LOG (never touches the operator's real
# ~/.claude/orchestrator-inline-guard/fires.jsonl) and feeds a synthetic
# transcript fixture so model detection is deterministic and hermetic.
#
# Usage: bash scripts/hooks/test-orchestrator-inline-guard.sh
# Exit codes: 0 - all cases passed; 1 - at least one failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/orchestrator-inline-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

assert_rc() {  # <label> <expected-rc> <actual-rc>
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $label (rc=$actual)"
        pass=$((pass + 1))
    else
        echo "  FAIL  $label - expected rc=$expected, got rc=$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {  # <label> <haystack> <needle>
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*)
            echo "  PASS  $label"
            pass=$((pass + 1))
            ;;
        *)
            echo "  FAIL  $label - did not find '$needle'"
            fail=$((fail + 1))
            ;;
    esac
}

assert_file_missing() {  # <label> <path>
    local label="$1" path="$2"
    if [ ! -e "$path" ]; then
        echo "  PASS  $label"
        pass=$((pass + 1))
    else
        echo "  FAIL  $label - expected absent: $path"
        fail=$((fail + 1))
    fi
}

# Build a transcript fixture whose last assistant turn carries the given model.
make_transcript() {  # $1 = dest path, $2 = model id
    printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}\n' > "$1"
    printf '{"type":"assistant","message":{"model":"%s","content":[{"type":"text","text":"ok"}]}}\n' "$2" >> "$1"
}

run_hook() {  # $1 = payload JSON, $2 = log path
    ORCH_GUARD_LOG="$2" bash "$HOOK" <<< "$1"
}

# --- Case 1: fires on matching model + tool + implementation path ---
OPUS_TRANSCRIPT="$TMP/opus-transcript.jsonl"
make_transcript "$OPUS_TRANSCRIPT" "claude-opus-4-8"
LOG1="$TMP/fires1.jsonl"
PAYLOAD1=$(jq -nc --arg tp "$OPUS_TRANSCRIPT" '{tool_name:"Edit",session_id:"sess-1",transcript_path:$tp,tool_input:{file_path:"scripts/hooks/foo.sh"}}')
OUT1=$(run_hook "$PAYLOAD1" "$LOG1")
RC1=$?
assert_rc "fires: always exits allow" 0 "$RC1"
assert_contains "fires: emits additionalContext nudge" "$OUT1" "orchestrating parent"
assert_contains "fires: log records the model" "$(cat "$LOG1" 2>/dev/null || true)" "claude-opus-4-8"
assert_contains "fires: log records the path" "$(cat "$LOG1" 2>/dev/null || true)" "scripts/hooks/foo.sh"

# --- Case 2: does NOT fire on a docs path (README.md under docs/) ---
LOG2="$TMP/fires2.jsonl"
PAYLOAD2=$(jq -nc --arg tp "$OPUS_TRANSCRIPT" '{tool_name:"Edit",session_id:"sess-2",transcript_path:$tp,tool_input:{file_path:"docs/internals/enforcement.md"}}')
OUT2=$(run_hook "$PAYLOAD2" "$LOG2")
RC2=$?
assert_rc "docs path: still allow" 0 "$RC2"
assert_rc "docs path: no additionalContext" 0 "$([ -z "$OUT2" ] && echo 0 || echo 1)"
assert_file_missing "docs path: no fire-log written" "$LOG2"

# --- Case 2b: CLAUDE.md inside an implementation dir is still docs (HIMMEL-1341 carve-out) ---
LOG2B="$TMP/fires2b.jsonl"
PAYLOAD2B=$(jq -nc --arg tp "$OPUS_TRANSCRIPT" '{tool_name:"Edit",session_id:"sess-2b",transcript_path:$tp,tool_input:{file_path:"scripts/hooks/CLAUDE.md"}}')
run_hook "$PAYLOAD2B" "$LOG2B" >/dev/null
assert_file_missing "CLAUDE.md under scripts/: no fire-log written" "$LOG2B"

# --- Case 2c: .claude/commands/*.md IS implementation surface (the carve-out's other half) ---
LOG2C="$TMP/fires2c.jsonl"
PAYLOAD2C=$(jq -nc --arg tp "$OPUS_TRANSCRIPT" '{tool_name:"Write",session_id:"sess-2c",transcript_path:$tp,tool_input:{file_path:".claude/commands/worktree.md"}}')
run_hook "$PAYLOAD2C" "$LOG2C" >/dev/null
assert_contains "command .md: fire-log written" "$(cat "$LOG2C" 2>/dev/null || true)" ".claude/commands/worktree.md"

# --- Case 3: does NOT fire on a non-top-tier model (sonnet) ---
SONNET_TRANSCRIPT="$TMP/sonnet-transcript.jsonl"
make_transcript "$SONNET_TRANSCRIPT" "claude-sonnet-5"
LOG3="$TMP/fires3.jsonl"
PAYLOAD3=$(jq -nc --arg tp "$SONNET_TRANSCRIPT" '{tool_name:"Edit",session_id:"sess-3",transcript_path:$tp,tool_input:{file_path:"scripts/hooks/foo.sh"}}')
OUT3=$(run_hook "$PAYLOAD3" "$LOG3")
RC3=$?
assert_rc "sonnet model: still allow" 0 "$RC3"
assert_rc "sonnet model: no additionalContext" 0 "$([ -z "$OUT3" ] && echo 0 || echo 1)"
assert_file_missing "sonnet model: no fire-log written" "$LOG3"

# --- Case 4: always allows regardless of trigger (jq missing -> fail-open) ---
LOG4="$TMP/fires4.jsonl"
# A PATH with every jq DIRECTORY filtered out — everything else (bash, tr,
# cat, mkdir, date, tail) still resolves from its own directory.
NO_JQ_PATH=""
while IFS= read -r dir; do
    if [ -x "$dir/jq" ] || [ -x "$dir/jq.exe" ]; then
        continue
    fi
    NO_JQ_PATH="${NO_JQ_PATH:+$NO_JQ_PATH:}$dir"
done <<< "$(printf '%s' "$PATH" | tr ':' '\n')"
PAYLOAD4=$(jq -nc --arg tp "$OPUS_TRANSCRIPT" '{tool_name:"Edit",session_id:"sess-4",transcript_path:$tp,tool_input:{file_path:"scripts/hooks/foo.sh"}}')
OUT4=$(PATH="$NO_JQ_PATH" ORCH_GUARD_LOG="$LOG4" bash "$HOOK" <<< "$PAYLOAD4" 2>/dev/null)
RC4=$?
assert_rc "jq missing: fail-open allow" 0 "$RC4"
assert_rc "jq missing: no additionalContext" 0 "$([ -z "$OUT4" ] && echo 0 || echo 1)"
assert_file_missing "jq missing: no fire-log written" "$LOG4"

# --- Case 5: ORCH_GUARD_DISABLE bypass short-circuits everything ---
LOG5="$TMP/fires5.jsonl"
OUT5=$(ORCH_GUARD_DISABLE=1 run_hook "$PAYLOAD1" "$LOG5")
RC5=$?
assert_rc "disable bypass: allow" 0 "$RC5"
assert_rc "disable bypass: no additionalContext" 0 "$([ -z "$OUT5" ] && echo 0 || echo 1)"
assert_file_missing "disable bypass: no fire-log written" "$LOG5"

echo ""
echo "orchestrator-inline-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
