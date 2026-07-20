#!/usr/bin/env bash
# Smoke test for scripts/hooks/guard-memory-capture.sh (HIMMEL-1088 / HIMMEL-570.3).
# Usage: bash scripts/hooks/test-guard-memory-capture.sh
# Exit: 0 all passed, 1 at least one failure.
#
# Rev2 note: the hook's adopter story is UNCONDITIONAL — no vault/qmd predicate,
# so these cases need neither LUNA_VAULT_PATH nor a lookup seam. HOME is still
# redirected into the sandbox for hermeticity (no real registry / capture log).
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/guard-memory-capture.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"
FAILED=0
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export HOME="$SB"                      # hermetic: no real registry / capture log
MEM="$SB/.claude/projects/proj/memory"; mkdir -p "$MEM"
export MEMORY_CAPTURE_LOG="$SB/capture.jsonl"

assert_rc() {
    if [ "$3" = "$2" ]; then echo "PASS $1 (rc=$3)"
    else echo "FAIL $1 (expected rc=$2, got $3)"; FAILED=1; fi
}

payload() { # $1=tool $2=file_path $3=content
    jq -nc --arg t "$1" --arg f "$2" --arg c "$3" \
      '{tool_name:$t,hook_event_name:"PreToolUse",tool_input:{file_path:$f,content:$c}}'
}

long="- $(printf 'x%.0s' $(seq 1 250)) -> luna [[n]]"
ok="- rtk masks gitleaks blocks -> luna [[himmel-harness-gotchas]]"
big="$(printf 'y%.0s' $(seq 1 900))"

# 1: >200-char line in MEMORY.md is DENIED.
printf -- '- short\n' > "$MEM/MEMORY.md"
payload Write "$MEM/MEMORY.md" "$long" | bash "$HOOK" >/dev/null 2>&1
assert_rc "over-length line denied" 2 "$?"

# 2: a compliant line is ALLOWED.
payload Write "$MEM/MEMORY.md" "$ok" | bash "$HOOK" >/dev/null 2>&1
assert_rc "compliant line allowed" 0 "$?"

# 3 (Rev2): a large topic-file body is ALLOWED — theme files are tier-2, unrestricted.
payload Write "$MEM/some-fact.md" "$big" | bash "$HOOK" >/dev/null 2>&1
assert_rc "large topic body allowed (tier-2, no body cap)" 0 "$?"

# 4 (Rev2): an Edit to a TOPIC file is ALLOWED — blanket Edit denial dropped for topic files.
jq -nc --arg f "$MEM/some-fact.md" '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"a",new_string:"b"}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "topic-file Edit allowed" 0 "$?"

# 5: *.bak EXEMPT.
payload Write "$MEM/MEMORY.md.bak" "$long" | bash "$HOOK" >/dev/null 2>&1
assert_rc "bak exempt" 0 "$?"

# 6: Edit to MEMORY.md DENIED (payload undecidable -> force whole-file Write).
jq -nc --arg f "$MEM/MEMORY.md" '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"a",new_string:"b"}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "Edit to MEMORY.md denied" 2 "$?"

# 7: paths OUTSIDE the memory dir untouched.
payload Write "$SB/unrelated.md" "$long" | bash "$HOOK" >/dev/null 2>&1
assert_rc "non-memory path ignored" 0 "$?"

# 8: net growth >400B DENIED.
printf -- '- a\n' > "$MEM/MEMORY.md"
grow="$(printf -- '- b -> luna [[n]]\n%.0s' $(seq 1 40))"
payload Write "$MEM/MEMORY.md" "$grow" | bash "$HOOK" >/dev/null 2>&1
assert_rc "net growth cap denied" 2 "$?"

# 9: >60-line MEMORY.md write DENIED (the structural ceiling, Rev2 D4).
#    Old file already at 62 lines and new content at 65 lines, each 4B: growth is
#    ~11B (< cap) so ONLY the ceiling can fire. Assert the deny rule to prove it.
: > "$MEMORY_CAPTURE_LOG"
for _ in $(seq 1 62); do printf -- '- x\n'; done > "$MEM/MEMORY.md"
ceil="$(for _ in $(seq 1 65); do printf -- '- x\n'; done)"
payload Write "$MEM/MEMORY.md" "$ceil" | bash "$HOOK" >/dev/null 2>&1
assert_rc "over-ceiling line count denied" 2 "$?"
grep -q '"rule":"line-ceiling"' "$MEMORY_CAPTURE_LOG"
assert_rc "ceiling deny logged with its own rule id" 0 "$?"

# 10: bypass wins over every deny branch (checked FIRST).
printf -- '- short\n' > "$MEM/MEMORY.md"
payload Write "$MEM/MEMORY.md" "$long" | MEMORY_CAPTURE_OK=1 bash "$HOOK" >/dev/null 2>&1
assert_rc "bypass allows a would-be deny" 0 "$?"

# 11: deny log carries a hash+excerpt record.
grep -q '"event":"deny"' "$MEMORY_CAPTURE_LOG" && grep -q '"hash"' "$MEMORY_CAPTURE_LOG"
assert_rc "deny logged with hash" 0 "$?"

# 12: an Edit deny logs the .new_string excerpt (INDEX_APPEND_TOOL=Edit, spike-confirmed).
#     Without the .new_string fallback every routine capture deny would log empty.
: > "$MEMORY_CAPTURE_LOG"
jq -nc --arg f "$MEM/MEMORY.md" '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"a",new_string:"UNIQUE-NEWSTR-9931"}}' \
  | bash "$HOOK" >/dev/null 2>&1
grep -q 'UNIQUE-NEWSTR-9931' "$MEMORY_CAPTURE_LOG"
assert_rc "Edit deny logs the new_string excerpt (not empty)" 0 "$?"

# --- Regression cases for the two FAIL-OPEN bugs found in review. Both shipped
# --- green against a naive suite. Do not remove.

# 13: ZERO '- ' lines must not crash the hook (grep -c prints 0 AND exits 1 ->
#     "0\n0" -> arithmetic error -> exit 1 -> PreToolUse fails OPEN, ungated).
printf 'no bullets at all\n' > "$MEM/MEMORY.md"
payload Write "$MEM/MEMORY.md" "still no bullets" | bash "$HOOK" >/dev/null 2>&1
assert_rc "zero-pointer-line content does not crash the hook" 0 "$?"

# 14: a WINDOWS backslash path must still be scoped (the POSIX glob never matches
#     C:\...\memory\MEMORY.md -> hook silently no-ops across its scope).
printf -- '- short\n' > "$MEM/MEMORY.md"
# tr with an octal backslash (\134) avoids sed's `\|`-as-escaped-delimiter trap
# in this Git-Bash sed AND tr's "unescaped backslash at end of string" warning.
winfp="$(printf '%s' "$MEM/MEMORY.md" | tr '/' '\134')"
payload Write "$winfp" "$long" | bash "$HOOK" >/dev/null 2>&1
assert_rc "backslash path still gated (not a silent no-op)" 2 "$?"

exit "$FAILED"
