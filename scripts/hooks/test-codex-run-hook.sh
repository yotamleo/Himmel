#!/usr/bin/env bash
# Unit test for .codex/run-hook.cmd + .codex/codex-hook-adapter.sh — the Codex
# hook wrapper + decision adapter (HIMMEL-427). Tests the UNIX (bash) branch of
# the polyglot. The Windows (cmd.exe) branch is tested by the .ps1 twin.
#
# Sets up an ISOLATED temp tree (<T>/.codex/{run-hook.cmd,codex-hook-adapter.sh}
# + <T>/scripts/hooks/...) so the test proves the wrapper derives the repo root
# from its OWN location, independent of the real repo.
set -uo pipefail
HOOKS="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="$HOOKS/../../.codex/run-hook.cmd"
ADAPTER="$HOOKS/../../.codex/codex-hook-adapter.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

[ -f "$WRAPPER" ] || { echo "wrapper not found: $WRAPPER" >&2; exit 1; }
[ -f "$ADAPTER" ] || { echo "adapter not found: $ADAPTER" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.codex" "$T/scripts/hooks"
cp "$WRAPPER" "$T/.codex/run-hook.cmd"
cp "$ADAPTER" "$T/.codex/codex-hook-adapter.sh"
# Canonical temp root (bash resolves symlinks via cd+pwd, mktemp may not).
TC="$(cd "$T" && pwd)"

# 1) ALLOW path: a guardrail that exits non-2 passes through unchanged — stdout,
#    a distinctive exit code, CLAUDE_PROJECT_DIR export, and stdin forwarding.
cat > "$T/scripts/hooks/dummy.sh" <<'EOF'
read -r line || true
echo "PROJDIR=[$CLAUDE_PROJECT_DIR]"
echo "STDIN=[$line]"
exit 7
EOF
out="$(printf 'fromstdin\n' | bash "$T/.codex/run-hook.cmd" dummy.sh)"; rc=$?
if [ "$rc" -eq 7 ]; then ok "non-block exit code propagates (rc=7)"; else bad "non-block exit code propagates (rc=$rc, want 7)"; fi
case "$out" in
  *"PROJDIR=[$TC]"*) ok "CLAUDE_PROJECT_DIR derived from wrapper location + exported";;
  *) bad "CLAUDE_PROJECT_DIR derived ($out)";;
esac
case "$out" in
  *"STDIN=[fromstdin]"*) ok "stdin forwarded to the guardrail";;
  *) bad "stdin forwarded ($out)";;
esac

# 2) BLOCK path: a guardrail that exits 2 is translated to Codex's JSON deny on
#    stdout (stderr -> reason) and the wrapper exits 0 (the block lives in the
#    JSON, not the exit code — Codex ignores exit 2). Use a DISTINCT inbound event
#    (PermissionRequest, not the PreToolUse default) so the hookEventName mirror
#    is load-bearing AND the non-PreToolUse path is covered.
cat > "$T/scripts/hooks/blocker.sh" <<'EOF'
read -r line || true
echo "blocking-reason-xyz" >&2
exit 2
EOF
bout="$(printf '{"hook_event_name":"PermissionRequest"}\n' | bash "$T/.codex/run-hook.cmd" blocker.sh)"; brc=$?
if [ "$brc" -eq 0 ]; then ok "block -> wrapper exits 0 (decision is in stdout JSON)"; else bad "block -> wrapper exits 0 (got $brc)"; fi
case "$bout" in
  *'"permissionDecision":"deny"'*) ok "block -> emits permissionDecision deny";;
  *) bad "block -> emits permissionDecision deny ($bout)";;
esac
case "$bout" in
  *"blocking-reason-xyz"*) ok "block -> guardrail stderr becomes the deny reason";;
  *) bad "block -> guardrail stderr becomes the deny reason ($bout)";;
esac
case "$bout" in
  *'"hookEventName":"PermissionRequest"'*) ok "block -> hookEventName mirrors the inbound event";;
  *) bad "block -> hookEventName mirrors the inbound event ($bout)";;
esac

# 3) FAIL-CLOSED paths: under Codex a bare exit 2 fails OPEN, so the adapter must
#    emit a JSON deny (exit 0) on its own precondition errors, not just on a
#    guardrail block.
# 3a) Missing script name -> fail closed (deny, rc 0), not a non-blocking error.
nout="$(printf '' | bash "$T/.codex/run-hook.cmd" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$nout" | grep -q '"permissionDecision":"deny"'; then
  ok "missing script name -> fail-closed deny (rc 0)"
else bad "missing script name -> fail-closed deny (rc=$rc, out=$nout)"; fi
# 3b) Referenced guardrail file does not exist -> fail closed (deny, rc 0).
gout="$(printf '{}' | bash "$T/.codex/run-hook.cmd" nonexistent-guardrail.sh 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$gout" | grep -q '"permissionDecision":"deny"'; then
  ok "missing guardrail file -> fail-closed deny (rc 0)"
else bad "missing guardrail file -> fail-closed deny (rc=$rc, out=$gout)"; fi
# 3c) Adapter invoked with CLAUDE_PROJECT_DIR unset -> fail closed (deny, rc 0).
#     (The wrapper always exports it; this locks the adapter's own guard.)
uout="$(printf '{}' | env -u CLAUDE_PROJECT_DIR bash "$T/.codex/codex-hook-adapter.sh" somehook.sh 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$uout" | grep -q '"permissionDecision":"deny"'; then
  ok "unset CLAUDE_PROJECT_DIR -> fail-closed deny (rc 0)"
else bad "unset CLAUDE_PROJECT_DIR -> fail-closed deny (rc=$rc, out=$uout)"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
