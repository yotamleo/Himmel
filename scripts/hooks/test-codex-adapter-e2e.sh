#!/usr/bin/env bash
# Through-adapter e2e for the codex-direct lane (HIMMEL-745 acceptance). Drives
# .codex/codex-hook-adapter.sh END-TO-END: stdin = a codex-shaped PreToolUse
# JSON, CLAUDE_PROJECT_DIR pointed at THIS checkout so the adapter runs the REAL
# guardrails under scripts/hooks/. Asserts the exit-2 block is translated into
# Codex's JSON `permissionDecision:"deny"` for BOTH:
#   (a) a secret-read payload through block-read-secrets.sh, and
#   (b) an external-write payload through block-terminal-write-fence.sh
#       (the guard this ticket adds).
# Plus an ALLOW passthrough (a benign command through the new guard must NOT
# emit a deny). Companion to scripts/hooks/test-codex-run-hook.sh, which proves
# the wrapper+adapter mechanics on a synthetic guardrail; this proves the real
# guardrails deny through the adapter. Hermetic: no network, no fixtures needed
# (both deny cases classify by the payload alone).
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HOOKS/../.." && pwd)"
ADAPTER="$REPO/.codex/codex-hook-adapter.sh"
[ -f "$ADAPTER" ] || { echo "adapter not found: $ADAPTER" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# The adapter must never see the external-write opt-in from the suite env.
unset CODEX_EXTERNAL_WRITES_OK 2>/dev/null || true

# run <guardrail.sh> <json> -> echoes adapter stdout; exit code in $rc
run() {
    local script="$1" json="$2"
    CLAUDE_PROJECT_DIR="$REPO" bash "$ADAPTER" "$script" <<EOF
$json
EOF
}

echo "== (a) secret-read through block-read-secrets.sh =="
out="$(run block-read-secrets.sh '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x/.env"}}')"; rc=$?
if [ "$rc" -eq 0 ]; then ok "adapter exits 0 (decision is in the JSON)"; else bad "adapter exits 0 (got $rc)"; fi
case "$out" in
  *'"permissionDecision":"deny"'*) ok "secret read -> JSON deny";;
  *) bad "secret read -> JSON deny ($out)";;
esac
case "$out" in
  *'"hookEventName":"PreToolUse"'*) ok "secret read -> hookEventName PreToolUse";;
  *) bad "secret read -> hookEventName PreToolUse ($out)";;
esac

echo "== (b) external-write through block-terminal-write-fence.sh =="
out="$(run block-terminal-write-fence.sh '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push origin main"}}')"; rc=$?
if [ "$rc" -eq 0 ]; then ok "adapter exits 0 (decision is in the JSON)"; else bad "adapter exits 0 (got $rc)"; fi
case "$out" in
  *'"permissionDecision":"deny"'*) ok "git push -> JSON deny";;
  *) bad "git push -> JSON deny ($out)";;
esac
case "$out" in
  *"external-write"*) ok "git push -> reason names the external-write class";;
  *) bad "git push -> reason names the external-write class ($out)";;
esac

echo "== (b') benign command through block-terminal-write-fence.sh -> ALLOW =="
out="$(run block-terminal-write-fence.sh '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}')"; rc=$?
if [ "$rc" -eq 0 ]; then ok "benign command -> adapter exits 0"; else bad "benign command -> adapter exits 0 (got $rc)"; fi
case "$out" in
  *permissionDecision*) bad "benign command -> must NOT emit a deny ($out)";;
  *) ok "benign command -> no permissionDecision (passthrough allow)";;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
