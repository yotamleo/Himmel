#!/usr/bin/env bash
# Smoke suite for scripts/hooks/guard-bus-store.sh (HIMMEL-4829, himmel-bus T6).
# A speed bump over the himmel-bus store (threat model T3, T5, T6): a session's
# Bash/Write/Edit that reaches under the bus root, calls `bus register|bind|
# rebind`, or assigns HIMMEL_BUS_* is denied; `bus status|peers|wait|send|adopt`
# stay allowed. Fails CLOSED on a payload it cannot parse that names the bus
# root. The guard is text matching: the "residual" rows pin what it deliberately
# does NOT catch, so nobody mistakes it for a fence.
#
# Payloads are built with jq from plain strings, so no row needs shell quoting.
# bash 3.2-safe. Platform guard (gitbash-only): env + jq, no git/path work.
# The single-quoted $VAR rows are literal command text, never expanded.
# shellcheck disable=SC2016
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/guard-bus-store.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

ROOT='/var/tmp/fixture-state/himmel/bus'

bash_json()  { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
file_json()  { jq -nc --arg t "$1" --arg p "$2" '{tool_name:$t,tool_input:{file_path:$p,content:"x"}}'; }

# run <json> [ENV=val ...] -> sets RC and OUT
run() {
    local json="$1"; shift
    OUT="$(printf '%s' "$json" | env -u BUS_STORE_GUARD_OK "$@" bash "$HOOK" 2>/dev/null)"
    RC=$?
}

deny()  { # deny <label> <json> [ENV=val ...]
    local label="$1" json="$2"; shift 2
    run "$json" "$@"
    local reason
    reason="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)"
    case "$reason" in
        "bus store-deny: "*) if [ "$RC" = 2 ]; then ok "$label"; else bad "$label - reason ok but rc=$RC"; fi ;;
        *) bad "$label - expected deny (rc=$RC) got: $OUT" ;;
    esac
}
allow() { # allow <label> <json> [ENV=val ...]  — allow must be rc 0 AND silent
    local label="$1" json="$2"; shift 2
    run "$json" "$@"
    if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "$label"; else
        bad "$label - expected silent allow, rc=$RC out=$OUT"; fi
}

[ -f "$HOOK" ] || { bad "hook not found: $HOOK"; echo "Summary: $pass passed, $fail failed"; exit 1; }

echo "== T3: registration verbs and env =="
deny "bus register x --role console" "$(bash_json 'bus register x --role console')"
deny "bus bind x 1" "$(bash_json 'bus bind x 1')"
deny "bus rebind x 1" "$(bash_json 'bus rebind x 1')"
deny "path-qualified bin/bus register" "$(bash_json 'node marketplace/plugins/himmel-bus/bin/bus register x --role leg')"
deny "register after a benign command" "$(bash_json 'echo hi; bus register x --role leg')"
deny "HIMMEL_BUS_NAME=x claude" "$(bash_json 'HIMMEL_BUS_NAME=x claude')"
deny "export HIMMEL_BUS_NAME=x" "$(bash_json 'export HIMMEL_BUS_NAME=x; claude')"
deny "env HIMMEL_BUS_NAME=x claude" "$(bash_json 'env HIMMEL_BUS_NAME=x claude')"

echo "== T3/T6: writes under the bus root =="
deny "printf into peers/x.json" "$(bash_json "printf '{}' > $ROOT/peers/x.json")"
deny "tee into the log" "$(bash_json "echo x | tee -a $ROOT/log/a.jsonl")"
deny "XDG-relative spelling" "$(bash_json 'echo x >> "$XDG_STATE_HOME/himmel/bus/cur/a"')"
deny "tilde spelling" "$(bash_json 'rm -f ~/.local/state/himmel/bus/peers/x.json')"
deny "relative spelling after cd" "$(bash_json 'cd ~/.local/state && echo x > himmel/bus/cur/a')"
deny "Write under the bus root" "$(file_json Write "$ROOT/peers/x.json")"
deny "Edit under the bus root" "$(file_json Edit "$ROOT/cur/a")"
deny "MultiEdit under the bus root" "$(file_json MultiEdit "$ROOT/log/a.jsonl")"
deny "Write via .. segments" "$(file_json Write "/tmp/../var/tmp/fixture-state/himmel/bus/peers/y.json")"

echo "== T5: reads under the bus root =="
deny "cat a log" "$(bash_json "cat $ROOT/log/other.jsonl")"
deny "head a log" "$(bash_json "head -n 5 $ROOT/log/other.jsonl")"
deny "grep the log dir" "$(bash_json "grep -r token $ROOT/log/")"
deny "ls the bus root" "$(bash_json "ls $ROOT")"

echo "== allowed bus verbs =="
allow "bus status" "$(bash_json 'bus status')"
allow "bus status <name>" "$(bash_json 'bus status x')"
allow "bus peers" "$(bash_json 'bus peers')"
allow "bus wait" "$(bash_json 'bus wait --for x')"
allow "bus send" "$(bash_json 'bus send console /tmp/body.txt --re 4')"
allow "bus adopt" "$(bash_json 'bus adopt new-console')"
allow "path-qualified bin/bus send" "$(bash_json 'node marketplace/plugins/himmel-bus/bin/bus send console /tmp/b.txt')"

echo "== unrelated work stays silent =="
allow "plain ls" "$(bash_json 'ls -la')"
allow "git grep for the env var name" "$(bash_json 'git grep HIMMEL_BUS_NAME scripts')"
allow "echo of the env var" "$(bash_json 'echo $HIMMEL_BUS_NAME')"
allow "himmel-bus plugin path (hyphen)" "$(bash_json 'ls marketplace/plugins/himmel-bus/lib')"
allow "bus-deliver hook path" "$(bash_json 'bash scripts/hooks/bus-deliver-hook.sh')"
allow "Write to an ordinary file" "$(file_json Write '/tmp/x.txt')"
allow "Edit in the himmel-bus plugin" "$(file_json Edit 'marketplace/plugins/himmel-bus/lib/store.mjs')"
allow "non-Bash non-file tool" "$(jq -nc '{tool_name:"Agent",tool_input:{prompt:"cat himmel/bus/log/a"}}')"

echo "== fail closed on an unparseable payload that names the root =="
run "not json at all: cat $ROOT/log/a.jsonl"
if [ "$RC" = 2 ]; then ok "garbage naming the bus root -> deny"; else bad "garbage naming the root: rc=$RC"; fi
run "not json at all"
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "garbage not naming the root -> allow, silent"; else bad "garbage without root: rc=$RC out=$OUT"; fi
run ''
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "empty stdin -> allow, silent"; else bad "empty stdin: rc=$RC out=$OUT"; fi
run '{"tool_name":"Bash","tool_input":{"command":["cat","himmel/bus/log/a"]}}'
if [ "$RC" = 2 ]; then ok "non-string command naming the root -> deny"; else bad "non-string command: rc=$RC"; fi

echo "== bypass =="
allow "BUS_STORE_GUARD_OK=1 + bus register -> allow" "$(bash_json 'bus register x --role leg')" BUS_STORE_GUARD_OK=1
deny  "BUS_STORE_GUARD_OK=0 does not bypass" "$(bash_json 'bus register x --role leg')" BUS_STORE_GUARD_OK=0

echo "== residual: a speed bump, not a fence (pins what text matching misses) =="
allow "residual: interpreter assembles the path" \
    "$(bash_json "python3 -c \"import os; open(os.path.expanduser('~/.local/state/hi'+'mmel/b'+'us/cur/a'),'w')\"")"

echo
echo "Summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
