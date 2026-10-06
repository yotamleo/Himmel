#!/usr/bin/env bash
# Smoke suite for scripts/hooks/guard-leg-context-handoff.sh (HIMMEL-4569): a
# console-spawned leg at >= 75 % context fill is denied ordinary tool calls
# until its RESUME doc exists or its last marker is WRAPPED/BLOCKED, while the
# hand-off calls themselves always pass. Every case runs against a synthetic
# session: a transcript whose first user turn is the launcher's
# `load <doc> and continue`, plus the claude-hud snapshot context-fill.sh reads.
#
# bash 3.2-safe. Platform guard (gitbash-only): env vars, jq, sha256sum/shasum,
# touch -t; no .ps1 twin (the hook has none).
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/guard-leg-context-handoff.sh"

# HIMMEL-3092: a console leg's own exports (HIMMEL_CONSOLE_LEG, ...) must not
# reach the hook under test; each case sets what it needs on its own call.
# shellcheck source=../lib/override-env.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/override-env.sh"
scrub_override_env
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_NAME HANDOVER_DIR CLAUDE_CONFIG_DIR \
    CONTEXT_FILL_TRANSCRIPT CLAUDE_CODE_SESSION_ID CLAUDE_PID
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/guard-leg-ctx.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"
CFG="$T/cfg"
DIR="$T/handovers/u/himmel"
mkdir -p "$CFG/projects/p" "$CFG/plugins/claude-hud/context-cache" "$DIR"
DOC="$DIR/HIMMEL-9-N77-thing-2026-10-06.md"
TR="$CFG/projects/p/sess.jsonl"
LEG_ENV="HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=T-console CLAUDE_CONFIG_DIR=$CFG HANDOVER_DIR=$T/handovers"

sha() {
    if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -d' ' -f1
    else printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; fi
}

# session <first-user-text> [timestamp] -- a fresh transcript whose first user turn says it
session() {
    jq -cn --arg t "$1" --arg ts "${2-2026-10-06T10:00:00.000Z}" \
        '{type:"user",timestamp:$ts,message:{role:"user",content:$t}}' > "$TR"
    printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":1}}}' >> "$TR"
}
# fill <pct> -- a fresh HUD snapshot for the transcript at that fill
fill() {
    printf '{"used_percentage":%s,"remaining_percentage":%s,"context_window_size":200000,"saved_at":%s000}' \
        "$1" "$((100 - $1))" "$(date +%s)" > "$CFG/plugins/claude-hud/context-cache/$(sha "$TR").json"
}
nofill() { rm -f "$CFG/plugins/claude-hud/context-cache/"*.json; }
# doc <last bullet>
doc() { printf -- '---\n---\n# brief\n\n## Results (newest at the bottom)\n\n%s\n' "$1" > "$DOC"; }

# check <label> <block|allow> <json> [extra ENV=val ...] -- leg env applied
check() {
    local label="$1" expect="$2" json="$3"; shift 3
    local rc got
    # shellcheck disable=SC2086  # LEG_ENV is a deliberate word list
    printf '%s' "$json" | env $LEG_ENV "$@" bash "$HOOK" >/dev/null 2>&1
    rc=$?
    case "$rc" in 0) got=allow ;; 2) got=block ;; *) got="?(rc=$rc)" ;; esac
    if [ "$got" = "$expect" ]; then ok "$label"; else bad "$label - expected $expect got $got"; fi
}
bash_call() { jq -cn --arg c "$1" --arg t "$TR" '{tool_name:"Bash",tool_input:{command:$c},transcript_path:$t}'; }
tool_call() { jq -cn --arg n "$1" --arg t "$TR" '{tool_name:$n,tool_input:{},transcript_path:$t}'; }
write_call() { jq -cn --arg n "$1" --arg p "$2" --arg t "$TR" '{tool_name:$n,tool_input:{file_path:$p,content:"x"},transcript_path:$t}'; }

session "load $DOC and continue"
doc "- 10:01 LIVE — working"
LS="$(bash_call 'ls')"

echo "== the threshold =="
fill 76; check "76 % + ordinary Bash -> block" block "$LS"
fill 75; check "75 % (the threshold itself) -> block" block "$LS"
fill 60; check "60 % -> allow" allow "$LS"
fill 74; check "74 % -> allow" allow "$LS"
fill 76
check "76 % + Read -> block" block "$(tool_call Read)"
check "76 % + Write to an ordinary file -> block" block "$(write_call Write "$T/notes.md")"

echo "== the deny message tells the leg exactly what to do =="
# shellcheck disable=SC2086
out="$(printf '%s' "$LS" | env $LEG_ENV bash "$HOOK" 2>/dev/null)"
reason="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
if [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ]; then
    ok "structured permissionDecision is deny"
else
    bad "no structured deny - got: $out"
fi
for needle in "76 %" "$DIR/HIMMEL-9-N77b-thing-2026-10-06-RESUME.md" T-console \
    "append-results.sh $DOC" "Do exactly this" LEG_CONTEXT_HANDOFF_OK; do
    case "$reason" in
        *"$needle"*) ok "deny text names: $needle" ;;
        *) bad "deny text lacks '$needle' - got: $reason" ;;
    esac
done
check "bypass LEG_CONTEXT_HANDOFF_OK=1 -> allow" allow "$LS" LEG_CONTEXT_HANDOFF_OK=1

echo "== non-leg sessions are untouched =="
# shellcheck disable=SC2086
if printf '%s' "$LS" | env CLAUDE_CONFIG_DIR="$CFG" HANDOVER_DIR="$T/handovers" HIMMEL_CONSOLE_LEG=1 bash "$HOOK" >/dev/null 2>&1; then
    ok "no HIMMEL_CONSOLE_NAME at 76 % -> allow"
else
    bad "no HIMMEL_CONSOLE_NAME at 76 % -> blocked"
fi
if printf '%s' "$LS" | env CLAUDE_CONFIG_DIR="$CFG" HANDOVER_DIR="$T/handovers" HIMMEL_CONSOLE_NAME=T-console bash "$HOOK" >/dev/null 2>&1; then
    ok "no HIMMEL_CONSOLE_LEG at 76 % -> allow"
else
    bad "no HIMMEL_CONSOLE_LEG at 76 % -> blocked"
fi
silent_out="$(printf '%s' "$LS" | env CLAUDE_CONFIG_DIR="$CFG" bash "$HOOK" 2>&1)"
if [ -z "$silent_out" ]; then ok "non-leg -> no output at all"; else bad "non-leg printed: $silent_out"; fi

echo "== hand-off calls always pass at 76 % =="
RESUME="$DIR/HIMMEL-9-N77b-thing-2026-10-06-RESUME.md"
check "Write the RESUME doc -> allow" allow "$(write_call Write "$RESUME")"
check "Edit the RESUME doc -> allow" allow "$(write_call Edit "$RESUME")"
check "SendMessage -> allow" allow "$(tool_call SendMessage)"
check "ListAgents -> allow" allow "$(tool_call ListAgents)"
check "TaskStop -> allow" allow "$(tool_call TaskStop)"
check "ToolSearch -> allow" allow "$(tool_call ToolSearch)"
check "append-results.sh -> allow" allow \
    "$(bash_call "bash scripts/handover/console-kit/append-results.sh $DOC \"BLOCKED — context 76 %; ctx; see \`RESUME\`\"")"
check "absolute append-results.sh -> allow" allow \
    "$(bash_call "bash /x/himmel/scripts/handover/console-kit/append-results.sh $DOC \"WRAPPED — done\"")"
check "queue-lock.sh release -> allow" allow "$(bash_call "bash scripts/handover/queue-lock.sh release $DOC \`tok\`")"
check "wrap-subtree-check.sh -> allow" allow "$(bash_call 'bash scripts/handover/wrap-subtree-check.sh')"
check "context-fill.sh probe -> allow" allow "$(bash_call 'bash scripts/context-fill.sh --percent')"
check "queue-lock.sh acquire -> block (not a hand-off)" block "$(bash_call "bash scripts/handover/queue-lock.sh acquire $DOC")"
check "append-results.sh && more -> block" block \
    "$(bash_call "bash scripts/handover/console-kit/append-results.sh $DOC \"LIVE x\" && rm -rf /tmp/x")"
check "append-results.sh || more -> block" block \
    "$(bash_call "bash scripts/handover/console-kit/append-results.sh $DOC \"LIVE x\" || ls")"
check "append-results.sh with \$( -> block" block \
    "$(bash_call "bash scripts/handover/console-kit/append-results.sh $DOC \"\$(ls)\"")"
check "echo naming append-results.sh -> block" block "$(bash_call 'echo scripts/handover/console-kit/append-results.sh')"

echo "== the exemptions: a RESUME doc exists, or the last marker is WRAPPED/BLOCKED =="
printf 'resume\n' > "$RESUME"
check "fresh N77b RESUME doc -> allow" allow "$LS"
touch -t 202001010000 "$RESUME"
check "RESUME doc older than this session -> block" block "$LS"
session "load $DOC and continue" "2026-10-06T12:00:00+02:00"
check "session start unparsable + old RESUME doc -> block" block "$LS"
session "load $DOC and continue" ""
check "session start missing + old RESUME doc -> block" block "$LS"
session "load $DOC and continue"
rm -f "$RESUME"
printf 'other leg\n' > "$DIR/HIMMEL-9-N78b-thing-2026-10-06-RESUME.md"
check "another leg's RESUME doc -> block" block "$LS"
printf 'longer id\n' > "$DIR/HIMMEL-9-N770b-thing-2026-10-06-RESUME.md"
check "a longer id sharing the prefix (N770) -> block" block "$LS"
doc "- 10:01 WRAPPED — merged"
check "last marker WRAPPED -> allow" allow "$LS"
doc "- 10:01 BLOCKED — waiting on console"
check "last marker BLOCKED -> allow" allow "$LS"
doc "- 10:01 FINDING — question"
check "last marker FINDING -> block" block "$LS"
doc "- 10:01 LIVE — working"

echo "== a resumed leg: its own RESUME-named doc is not its hand-off =="
DOC2="$DIR/HIMMEL-9-N77b-thing-2026-10-06-RESUME.md"
printf -- '# resumed\n\n## Results\n\n- 10:01 LIVE — resumed\n' > "$DOC2"
session "load $DOC2 and continue"
fill 76
check "resumed leg, only its own doc -> block" block "$LS"
# shellcheck disable=SC2086
reason="$(printf '%s' "$LS" | env $LEG_ENV bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
case "$reason" in
    *"HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"*) ok "resumed leg is told to write the N77c doc" ;;
    *) bad "resumed leg suggestion wrong - got: $reason" ;;
esac
printf 'next\n' > "$DIR/HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"
check "resumed leg + fresh N77c RESUME doc -> allow" allow "$LS"
rm -f "$DOC2" "$DIR/HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"
session "load $DOC and continue"

echo "== fail-open: fill UNKNOWN/STALE, leg doc unknown, junk input =="
nofill
check "no HUD snapshot (UNKNOWN) at would-be 76 % -> allow" allow "$LS"
# shellcheck disable=SC2086
warn="$(printf '%s' "$LS" | env $LEG_ENV bash "$HOOK" 2>&1 >/dev/null)"
case "$warn" in
    *guard-leg-context-handoff*) ok "UNKNOWN fill -> one-line warning on stderr" ;;
    *) bad "UNKNOWN fill -> no warning - got: $warn" ;;
esac
if [ "$(printf '%s\n' "$warn" | wc -l | tr -d ' ')" = 1 ]; then ok "warning is one line"; else bad "warning is not one line: $warn"; fi
printf '{"used_percentage":90,"remaining_percentage":10,"context_window_size":200000,"saved_at":1000}' \
    > "$CFG/plugins/claude-hud/context-cache/$(sha "$TR").json"
check "STALE snapshot at 90 % -> allow" allow "$LS"
fill 76
check "no transcript_path -> allow" allow '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
session "hello, no brief path here"
fill 76
check "leg doc not named in the first turn -> allow" allow "$LS"
session "load $DIR/missing-doc.md and continue"
fill 76
check "leg doc named but missing -> allow" allow "$LS"
session "load $DOC and continue"
fill 76
check "malformed JSON -> allow" allow '{not json'
check "empty stdin -> allow" allow ''

echo "== array-shaped first user turn =="
jq -cn --arg t "load $DOC and continue" \
    '{type:"user",timestamp:"2026-10-06T10:00:00.000Z",message:{role:"user",content:[{type:"text",text:$t}]}}' > "$TR"
fill 76
check "content as a text-block array -> leg doc found, block" block "$LS"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
