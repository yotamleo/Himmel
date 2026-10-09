#!/usr/bin/env bash
# scripts/handover/console-kit/test-live-subagents.sh - HIMMEL-5071 suite:
# live-subagents.sh (the detector) and the wrap gate it backs,
# `console.sh wrap`. The close gate's cases live in test-close-wrapped-leg.sh
# beside the rest of that script's cases.
#
# Hermetic: a fake ${CLAUDE_CONFIG_DIR}/projects tree holding one parent
# transcript and its subagents/ registry, shaped like Claude Code 2.1.295's
# (meta.json written at launch; the parent's `queue-operation` enqueue of a
# <task-notification> written when the child stops). HANDOVER_DIR is a scratch
# root, so the real queue locks are never touched.
#
# Platform guard: Linux bash 3.2+ (jq).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LS="$HERE/live-subagents.sh"
CONSOLE="$HERE/../console/console.sh"
QL="$HERE/../queue-lock.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/lsa-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
fails=0
check()    { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi; }
contains() { if grep -q -F -e "$3" <<< "$2"; then echo "ok - $1"; else echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); fi; }

SID="11111111-2222-3333-4444-555555555555"
PROJ="$W/cfg/projects/-fake-project"
PARENT="$PROJ/$SID.jsonl"
SUB="$PROJ/$SID/subagents"

reset_session() {
    rm -rf "$W/cfg"; mkdir -p "$SUB"
    printf '{"type":"user","timestamp":"2026-10-09T00:00:00.000Z","sessionId":"%s"}\n' "$SID" > "$PARENT"
}
# launch <agent-id> <tool-use-id> <shape> <child-last-ts> - the launch-time registry entry + child transcript
launch() {
    printf '{"agentType":"console-judge","description":"Judge j%s","toolUseId":"%s","requestShape":"%s"}\n' "$1" "$2" "$3" > "$SUB/agent-$1.meta.json"
    printf '{"type":"assistant","timestamp":"%s"}\n' "$4" >> "$SUB/agent-$1.jsonl"
}
# child_runs <agent-id> <ts> - the child writes another record (a resumed child)
child_runs() { printf '{"type":"assistant","timestamp":"%s"}\n' "$2" >> "$SUB/agent-$1.jsonl"; }
# notify <agent-id> <tool-use-id> <ts> - the parent's enqueue of the child's completion notice
notify() {
    jq -nc --arg a "$1" --arg t "$2" --arg ts "$3" --arg s "$SID" '{type:"queue-operation",operation:"enqueue",timestamp:$ts,sessionId:$s,
        content:("<task-notification>\n<task-id>" + $a + "</task-id>\n<tool-use-id>" + $t + "</tool-use-id>\n<status>completed</status>")}' >> "$PARENT"
}
# fg_result <tool-use-id> <ts> - a foreground child's tool_result in the parent
fg_result() {
    jq -nc --arg t "$1" --arg ts "$2" '{type:"user",timestamp:$ts,message:{content:[{type:"tool_result",tool_use_id:$t,content:"done"}]}}' >> "$PARENT"
}
detect() { CLAUDE_CONFIG_DIR="$W/cfg" bash "$LS" "$@"; }

# --- the detector -------------------------------------------------------------
reset_session
rc=0; out=$(detect --session "$SID" 2>&1) || rc=$?
check "detector: no children -> rc 0" "$rc" "0"
contains "detector: no children -> count 0" "$out" "live-subagents=0"

launch a1 toolu_A1 background 2026-10-09T00:01:00.000Z
rc=0; out=$(detect --session "$SID" 2>&1) || rc=$?
check "detector: launched, no completion notice -> rc 1" "$rc" "1"
contains "detector: names the live child" "$out" "LIVE-SUBAGENT a1 console-judge Judge ja1"

notify a1 toolu_A1 2026-10-09T00:01:00.010Z
rc=0; out=$(detect --session "$SID" 2>&1) || rc=$?
check "detector: completion enqueued (never delivered) -> rc 0" "$rc" "0"

child_runs a1 2026-10-09T00:05:00.000Z
rc=0; out=$(detect --session "$SID" 2>&1) || rc=$?
check "detector: resumed after its notice -> rc 1" "$rc" "1"
notify a1 toolu_RESUME_SENDMESSAGE 2026-10-09T00:05:00.020Z
rc=0; out=$(detect --session "$SID" 2>&1) || rc=$?
check "detector: resumed child's notice (SendMessage tool-use-id, same task-id) -> rc 0" "$rc" "0"

launch f1 toolu_F1 foreground 2026-10-09T00:06:00.000Z
rc=0; out=$(detect --session "$SID" 2>&1) || rc=$?
check "detector: foreground child without its tool_result -> rc 1" "$rc" "1"
fg_result toolu_F1 2026-10-09T00:06:00.050Z
rc=0; out=$(detect --session "$SID" 2>&1) || rc=$?
check "detector: foreground child with its tool_result -> rc 0" "$rc" "0"

rc=0; detect --session not-a-uuid >/dev/null 2>&1 || rc=$?
check "detector: unusable session id -> rc 2 (cannot decide)" "$rc" "2"
rc=0; detect --session "11111111-2222-3333-4444-55555555/../" >/dev/null 2>&1 || rc=$?
check "detector: a uuid-shaped id with a path separator -> rc 2" "$rc" "2"
rc=0; detect --session 99999999-2222-3333-4444-555555555555 >/dev/null 2>&1 || rc=$?
check "detector: no parent transcript -> rc 2 (cannot decide)" "$rc" "2"
printf 'not json\n' > "$SUB/agent-bad.meta.json"
rc=0; detect --session "$SID" >/dev/null 2>&1 || rc=$?
check "detector: unreadable registry entry -> rc 2 (cannot decide)" "$rc" "2"
rm -f "$SUB/agent-bad.meta.json"
rc=0; out=$(CLAUDE_CODE_SESSION_ID="$SID" detect 2>&1) || rc=$?
check "detector: defaults to \$CLAUDE_CODE_SESSION_ID" "$rc" "0"
rc=0; timeout 10 env CLAUDE_CONFIG_DIR="$W/cfg" bash "$LS" --session >/dev/null 2>&1 || rc=$?
check "detector: --session with no value -> rc 2 (no loop)" "$rc" "2"
printf 'not json\n' >> "$SUB/agent-a1.jsonl"
rc=0; detect --session "$SID" >/dev/null 2>&1 || rc=$?
check "detector: unparseable child transcript -> rc 2 (cannot decide)" "$rc" "2"
reset_session

# --- the wrap gate: console.sh wrap ------------------------------------------
# A predecessor console with a fake live judge child: wrap refused, nothing
# written, lock still held; the child stops: wrap writes WRAPPED and releases.
ROOT="$W/handover-root"
mkdir -p "$ROOT/u/b"
DOC="$ROOT/u/b/HIMMEL-nextleg-2026-10-09A-demo-console.md"
printf '# A console\n\n## Results (newest at the bottom)\n\n- 09:00 LIVE - console up\n' > "$DOC"
acq=$(HANDOVER_DIR="$ROOT" bash "$QL" acquire "$DOC" lsa-test-console 2>&1)
TOKEN=$(printf '%s\n' "$acq" | sed -n "s/^release-token: \`\(.*\)\`\$/\\1/p")
check "wrap fixture: lock acquired" "$([ -n "$TOKEN" ] && echo yes)" "yes"

reset_session
launch j1 toolu_J1 background 2026-10-09T01:00:00.000Z
wrap() {
    HANDOVER_DIR="$ROOT" CLAUDE_CONFIG_DIR="$W/cfg" CLAUDE_CODE_SESSION_ID="$SID" LEG_JIRA_STATUS=0 \
        bash "$CONSOLE" wrap "$@"
}
rc=0; out=$(wrap "$DOC" "$TOKEN" "handed to B" 2>&1) || rc=$?
check "wrap: live subagent -> refused rc 4" "$rc" "4"
contains "wrap: names the live child" "$out" "LIVE-SUBAGENT j1"
check "wrap: refused -> no WRAPPED written" "$(grep -c WRAPPED "$DOC")" "0"
rc=0; HANDOVER_DIR="$ROOT" bash "$QL" status "$DOC" >/dev/null 2>&1 || rc=$?
check "wrap: refused -> lock still held" "$([ "$rc" -ne 0 ] && echo held)" "held"

rc=0; out=$(HANDOVER_DIR="$ROOT" CLAUDE_CONFIG_DIR="$W/cfg" LEG_JIRA_STATUS=0 env -u CLAUDE_CODE_SESSION_ID bash "$CONSOLE" wrap "$DOC" "$TOKEN" "x" 2>&1) || rc=$?
check "wrap: no session id (cannot prove idle) -> refused rc 4" "$rc" "4"

notify j1 toolu_J1 2026-10-09T01:00:00.010Z
rc=0; out=$(wrap "$DOC" "not-the-token" "handed to B" 2>&1) || rc=$?
check "wrap: wrong release token -> refused" "$([ "$rc" -ne 0 ] && echo refused)" "refused"
check "wrap: wrong token -> no WRAPPED written" "$(grep -c WRAPPED "$DOC")" "0"
rc=0; out=$(wrap "$DOC" "$TOKEN" "handed to B" 2>&1) || rc=$?
check "wrap: child stopped -> rc 0" "$rc" "0"
check "wrap: WRAPPED is the last bullet" "$(grep '^- ' "$DOC" | tail -n 1 | sed -E 's/^- [0-9:]+ ([A-Z]+).*/\1/')" "WRAPPED"
rc=0; HANDOVER_DIR="$ROOT" bash "$QL" status "$DOC" >/dev/null 2>&1 || rc=$?
check "wrap: lock released" "$rc" "0"

rc=0; wrap "$DOC" >/dev/null 2>&1 || rc=$?
check "wrap: usage (missing token) -> rc 1" "$rc" "1"

if [ "$fails" -ne 0 ]; then
    echo "FAILED: $fails"
    exit 1
fi
echo "PASS"
