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

# bash-3.2-safe repeat helper (no `seq`, not guaranteed present on all
# supported macOS shells). $1=string to repeat, $2=repeat count.
repeat_char() {
    local s="$1" n="$2" i=0 out=""
    while [ "$i" -lt "$n" ]; do
        out="$out$s"
        i=$((i + 1))
    done
    printf '%s' "$out"
}

long="- $(repeat_char x 250) -> luna [[n]]"
ok="- rtk masks gitleaks blocks -> luna [[himmel-harness-gotchas]]"
big="$(repeat_char y 900)"
# 199 CHARACTERS with 20 em-dashes mixed in (each is 3 bytes, so the line is
# 239 BYTES): must be counted as chars, not bytes, or this trips the 200-char
# rule early (HIMMEL-2011). Kept well under the 400B growth cap so only the
# line-length rule is in play.
emdash_199="- $(repeat_char '—' 20)$(repeat_char x 177)"
# 201 ASCII chars (== 201 bytes either way): must still be denied.
ascii_201="- $(repeat_char x 199)"

# 1: >200-char line in MEMORY.md is DENIED.
printf -- '- short\n' > "$MEM/MEMORY.md"
payload Write "$MEM/MEMORY.md" "$long" | bash "$HOOK" >/dev/null 2>&1
assert_rc "over-length line denied" 2 "$?"

# 2: a compliant line is ALLOWED.
payload Write "$MEM/MEMORY.md" "$ok" | bash "$HOOK" >/dev/null 2>&1
assert_rc "compliant line allowed" 0 "$?"

# 2b (HIMMEL-2011): a 199-CHAR line with multibyte em-dashes (>200 bytes) is
# ALLOWED — the rule is char-based, and this env has no LANG/LC_ALL by default.
payload Write "$MEM/MEMORY.md" "$emdash_199" | bash "$HOOK" >/dev/null 2>&1
assert_rc "199-char em-dash line allowed (chars, not bytes)" 0 "$?"

# 2c (HIMMEL-2011): a 201-char ASCII line is still DENIED.
payload Write "$MEM/MEMORY.md" "$ascii_201" | bash "$HOOK" >/dev/null 2>&1
assert_rc "201-char ASCII line still denied" 2 "$?"

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

# 6 (HIMMEL-2011): Edit to MEMORY.md is DECIDABLE — simulated against the
# on-disk file and validated with the same checks as Write.
printf -- '- alpha route -> luna [[a]]\n' > "$MEM/MEMORY.md"
jq -nc --arg f "$MEM/MEMORY.md" '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"alpha",new_string:"beta"}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "valid Edit to MEMORY.md allowed" 0 "$?"

# 6b: an Edit whose simulated RESULT violates a rule is denied with the same
# reason a Write would get (one code path — checks run on the simulated $content).
printf -- '- alpha route -> luna [[a]]\n' > "$MEM/MEMORY.md"
: > "$MEMORY_CAPTURE_LOG"
longfill="$(repeat_char z 210)"
jq -nc --arg f "$MEM/MEMORY.md" --arg ns "$longfill" \
  '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"route",new_string:$ns}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "Edit whose simulated result is over-length is denied" 2 "$?"
grep -q '"rule":"line-too-long"' "$MEMORY_CAPTURE_LOG"
assert_rc "denied Edit logs the same rule id as Write (line-too-long)" 0 "$?"

# 6c: MultiEdit applies edits.[] SEQUENTIALLY (second old_string only exists
# after the first edit lands) and is allowed when the result is compliant.
printf -- '- alpha route -> luna [[a]]\n' > "$MEM/MEMORY.md"
jq -nc --arg f "$MEM/MEMORY.md" \
  '{tool_name:"MultiEdit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,edits:[{old_string:"alpha",new_string:"beta"},{old_string:"beta route",new_string:"beta path"}]}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "MultiEdit applies edits sequentially and is allowed" 0 "$?"

# 6d: old_string not found -> ALLOW (the Edit tool itself errors on this, not
# this guard).
printf -- '- alpha route -> luna [[a]]\n' > "$MEM/MEMORY.md"
jq -nc --arg f "$MEM/MEMORY.md" '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"NOPE-NOT-PRESENT",new_string:"x"}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "Edit old_string not found is allowed" 0 "$?"

# 6e (HIMMEL-2011, CR codex-2): the simulation must splice new_string LITERALLY.
#     `String.replace(str, str)` would expand the `$&` below into the 30-char
#     match, pushing the line from 184 to 214 chars -> a phantom line-too-long
#     deny on an edit that is actually compliant.
tok30="$(repeat_char T 30)"
printf -- '- %s\n' "$tok30" > "$MEM/MEMORY.md"
jq -nc --arg f "$MEM/MEMORY.md" --arg o "$tok30" --arg n "$(repeat_char x 180)\$&" \
  '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:$o,new_string:$n}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "Edit new_string with \$& is spliced literally (no pattern expansion)" 0 "$?"

# 6f (HIMMEL-2011, CR codex-1): trailing newlines must survive the simulation.
#     `$( )` strips them, so without the EOT sentinel this +500B edit measures
#     as -1B and slips past the 400B growth cap.
printf -- '- a\n' > "$MEM/MEMORY.md"
jq -nc --arg f "$MEM/MEMORY.md" \
  '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"a",new_string:("a" + ("\n" * 500))}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "Edit appending 500 trailing newlines hits the growth cap" 2 "$?"

# 6g (HIMMEL-2011, CR codex-2): a NON-ENOENT read error is undecidable, not an
#     empty new file — fail closed. A directory at the index path gives EISDIR.
rm -f "$MEM/MEMORY.md"; mkdir -p "$MEM/MEMORY.md"
jq -nc --arg f "$MEM/MEMORY.md" '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"a",new_string:"b"}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "unreadable MEMORY.md denies as undecidable (fail-closed)" 2 "$?"
rmdir "$MEM/MEMORY.md"

# 7: paths OUTSIDE the memory dir untouched.
payload Write "$SB/unrelated.md" "$long" | bash "$HOOK" >/dev/null 2>&1
assert_rc "non-memory path ignored" 0 "$?"

# 8: net growth >400B DENIED.
printf -- '- a\n' > "$MEM/MEMORY.md"
grow="$(repeat_char $'- b -> luna [[n]]\n' 40)"
payload Write "$MEM/MEMORY.md" "$grow" | bash "$HOOK" >/dev/null 2>&1
assert_rc "net growth cap denied" 2 "$?"

# 9: >60-line MEMORY.md write DENIED (the structural ceiling, Rev2 D4).
#    Old file already at 62 lines and new content at 65 lines, each 4B: growth is
#    ~11B (< cap) so ONLY the ceiling can fire. Assert the deny rule to prove it.
: > "$MEMORY_CAPTURE_LOG"
repeat_char $'- x\n' 62 > "$MEM/MEMORY.md"
ceil="$(repeat_char $'- x\n' 65)"
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

# 12 (HIMMEL-2011: Edit is decidable now, so this regression case moved to
#     NotebookEdit — the one tool_name still forced through the undecidable-
#     payload deny): a deny logs the .new_string excerpt (spike-confirmed
#     INDEX_APPEND_TOOL=Edit shape). Without the .new_string fallback every
#     such deny would log empty.
: > "$MEMORY_CAPTURE_LOG"
jq -nc --arg f "$MEM/MEMORY.md" '{tool_name:"NotebookEdit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"a",new_string:"UNIQUE-NEWSTR-9931"}}' \
  | bash "$HOOK" >/dev/null 2>&1
grep -q 'UNIQUE-NEWSTR-9931' "$MEMORY_CAPTURE_LOG"
assert_rc "NotebookEdit deny logs the new_string excerpt (not empty)" 0 "$?"

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

# --- HIMMEL-2074: line-too-long must be DIFF-SCOPED (added/changed lines
# --- only), not a whole-file re-scan of every PRE-EXISTING line. A legacy
# --- over-length line already committed to MEMORY.md (grandfathered before
# --- this rule existed, or before the cap was lowered) used to freeze the
# --- index — deny EVERY future write, even one that only appends an
# --- unrelated, fully-compliant new line.

legacy_bad="- $(repeat_char x 250) -> luna [[legacy]]"
# An em-dash-heavy legacy line genuinely over 200 CHARS (not just bytes) —
# the real shape reported in HIMMEL-2074 (a 227-char routing line with
# several em dashes already committed to the live MEMORY.md).
legacy_emdash="- $(repeat_char '—' 30)$(repeat_char x 190) -> luna [[legacy-emdash]]"

# 15: a pre-existing over-length line does not block a NEW compliant append.
printf -- '%s\n' "$legacy_bad" > "$MEM/MEMORY.md"
newcontent="$legacy_bad
- new short line -> luna [[n]]"
payload Write "$MEM/MEMORY.md" "$newcontent" | bash "$HOOK" >/dev/null 2>&1
assert_rc "pre-existing over-length line does not block a new compliant append" 0 "$?"

# 15b: a NEWLY added over-length line is still denied even alongside an
#      untouched pre-existing over-length line.
newcontent_bad="$legacy_bad
$long"
payload Write "$MEM/MEMORY.md" "$newcontent_bad" | bash "$HOOK" >/dev/null 2>&1
assert_rc "a newly added over-length line is still denied" 2 "$?"

# 15c: an Edit whose simulated result still carries an untouched pre-existing
#      over-length line ELSEWHERE in the file is ALLOWED — only what this
#      edit actually touched is checked.
printf -- '%s\n- alpha route -> luna [[a]]\n' "$legacy_bad" > "$MEM/MEMORY.md"
jq -nc --arg f "$MEM/MEMORY.md" '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"alpha",new_string:"beta"}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "Edit unrelated to a pre-existing over-length line is allowed" 0 "$?"

# 15d: editing the legacy over-length line ITSELF into something still
#      over-length is still denied (the edit target IS the changed line).
printf -- '%s\n' "$legacy_bad" > "$MEM/MEMORY.md"
jq -nc --arg f "$MEM/MEMORY.md" --arg ns "$(repeat_char y 250)" \
  '{tool_name:"Edit",hook_event_name:"PreToolUse",tool_input:{file_path:$f,old_string:"legacy",new_string:$ns}}' \
  | bash "$HOOK" >/dev/null 2>&1
assert_rc "editing the legacy line itself into another over-length line is still denied" 2 "$?"

# 15f (CR round 1, codex-1): a NEW occurrence of text that happens to be
#     BYTE-IDENTICAL to an already-grandfathered over-length line must still
#     be checked (and denied) — a plain set-difference ("does this new line's
#     text appear anywhere in old?") would wrongly treat the second, genuinely
#     new copy as "already existed" and skip it entirely. Multiset (bag)
#     difference closes this: the duplicate is a fresh occurrence beyond what
#     old already had.
printf -- '%s\n' "$legacy_bad" > "$MEM/MEMORY.md"
dup_content="$legacy_bad
$legacy_bad"
payload Write "$MEM/MEMORY.md" "$dup_content" | bash "$HOOK" >/dev/null 2>&1
assert_rc "a duplicated copy of a grandfathered over-length line is still denied" 2 "$?"

# 15g (CR round 2, codex-1): an on-disk MEMORY.md with CRLF line endings must
#     not make every untouched line look "added" (a trailing \r on the OLD
#     line vs an LF-only new payload) and resurrect the pre-existing-line
#     re-validation bug this whole fix exists to close.
printf -- '%s\r\n' "$legacy_bad" > "$MEM/MEMORY.md"
newcontent_crlf="$legacy_bad
- new short line -> luna [[n]]"
payload Write "$MEM/MEMORY.md" "$newcontent_crlf" | bash "$HOOK" >/dev/null 2>&1
assert_rc "a CRLF-terminated pre-existing over-length line does not block a new compliant append" 0 "$?"

# 15e: same as 15, but the legacy over-length line is an EM-DASH-HEAVY line
#      (the exact repro shape from HIMMEL-2074's live MEMORY.md) — a new
#      compliant append still lands.
printf -- '%s\n' "$legacy_emdash" > "$MEM/MEMORY.md"
newcontent_emdash="$legacy_emdash
- new short line -> luna [[n]]"
payload Write "$MEM/MEMORY.md" "$newcontent_emdash" | bash "$HOOK" >/dev/null 2>&1
assert_rc "an em-dash-heavy pre-existing over-length line does not block a new compliant append" 0 "$?"

exit "$FAILED"
