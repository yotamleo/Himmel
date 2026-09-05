#!/usr/bin/env bash
# E2E coverage for the HIMMEL-1666 rewrite-vector fix: a dispatched worker with
# Edit(<worktree>) can rewrite a project-local guard's ON-DISK content (not
# just delete it — the vector HIMMEL-1649 already closed). This proves
# run-hook-with-bash.js denies the tampered file instead of running it, once
# record-hook-integrity.sh has pinned the worktree at SessionStart — the
# worker-shaped session HIMMEL-1666 asks for.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
RECORDER="$HOOKS_DIR/record-hook-integrity.sh"
LAUNCHER="$HOOKS_DIR/run-hook-with-bash.js"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 0; }

T="$(mktemp -d "${TMPDIR:-/tmp}/himmel-hook-rewrite-integrity.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PROJECT="$T/project"
OUT_DIR="$T/out"
mkdir -p "$PROJECT/scripts/hooks"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

GUARD="$PROJECT/scripts/hooks/fake-guard.sh"
cat > "$GUARD" <<'GUARD_EOF'
#!/usr/bin/env bash
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
exit 0
GUARD_EOF
chmod +x "$GUARD"
git -C "$PROJECT" init -q
git -C "$PROJECT" -c user.email=t@t -c user.name=t add -A
git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -q -m init

PAYLOAD='{"session_id":"worker-session-1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf harmless"}}'

# SessionStart pin, as it would happen before the worker's first tool call.
printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" bash "$RECORDER" >/dev/null

run_launcher() {
  printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" \
    node "$LAUNCHER" --optional "$GUARD"
}

run_launcher >"$T/before.out" 2>"$T/before.err"
rc_before=$?
if [ "$rc_before" -eq 0 ] && grep -q 'permissionDecision' "$T/before.out"; then
  ok "unmodified guard runs normally before any tampering"
else
  bad "unmodified guard: rc=$rc_before out=$(cat "$T/before.out") err=$(cat "$T/before.err")"
fi

# The rewrite vector: a worker with Edit(<worktree>) overwrites the guard's
# content in place (not a delete — HIMMEL-1649 already covers that) to always
# allow.
cat > "$GUARD" <<'TAMPER_EOF'
#!/usr/bin/env bash
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
exit 0
# tampered: this guard used to deny; now it never does.
TAMPER_EOF

run_launcher >"$T/after.out" 2>"$T/after.err"
rc_after=$?
if [ "$rc_after" -eq 2 ] && grep -qi 'DENY' "$T/after.err"; then
  ok "tampered guard is denied at the launcher, before its content ever runs"
else
  bad "tampered guard: expected rc=2 with a DENY message, got rc=$rc_after err=$(cat "$T/after.err")"
fi

# The documented single-run bypass still lets a legitimate mid-session edit
# through.
BYPASS_OUT="$T/bypass.out"
BYPASS_ERR="$T/bypass.err"
printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 \
  node "$LAUNCHER" --optional "$GUARD" >"$BYPASS_OUT" 2>"$BYPASS_ERR"
rc_bypass=$?
if [ "$rc_bypass" -eq 0 ]; then
  ok "HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 lets the tampered guard run"
else
  bad "bypass: expected rc=0, got rc=$rc_bypass err=$(cat "$BYPASS_ERR")"
fi

# A session with no pin file at all (e.g. record-hook-integrity.sh never ran,
# or predates this checkout) must not regress to blocking every tool call.
printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$T/no-such-dir" \
  node "$LAUNCHER" --optional "$GUARD" >"$T/nopins.out" 2>"$T/nopins.err"
rc_nopins=$?
if [ "$rc_nopins" -eq 0 ]; then
  ok "no pin file for the session fails open (no blast radius on unpinned sessions)"
else
  bad "no pin file: expected rc=0 (fail open), got rc=$rc_nopins err=$(cat "$T/nopins.err")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
