#!/usr/bin/env bash
# Smoke test for record-hook-integrity.sh (HIMMEL-1666).
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HOOKS_DIR/record-hook-integrity.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }

T="$(mktemp -d "${TMPDIR:-/tmp}/himmel-record-hook-integrity.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PROJECT="$T/project"
OUT_DIR="$T/out"
mkdir -p "$PROJECT/scripts/hooks" "$PROJECT/scripts/guardrails"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

printf 'echo hook-a\n' > "$PROJECT/scripts/hooks/hook-a.sh"
printf 'echo guard-b\n' > "$PROJECT/scripts/guardrails/guard-b.sh"
git -C "$PROJECT" init -q
git -C "$PROJECT" -c user.email=t@t -c user.name=t add -A
git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -q -m init

PAYLOAD='{"session_id":"test-session-1","source":"startup"}'
printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" bash "$SCRIPT"
rc=$?

PIN_FILE="$OUT_DIR/test-session-1.json"
if [ "$rc" -eq 0 ] && [ -f "$PIN_FILE" ]; then
  ok "hook exits 0 and writes a pin file"
else
  bad "hook exited $rc, pin file present=$( [ -f "$PIN_FILE" ] && echo yes || echo no )"
fi

expected_a="$(git -C "$PROJECT" rev-parse HEAD:scripts/hooks/hook-a.sh)"
expected_b="$(git -C "$PROJECT" rev-parse HEAD:scripts/guardrails/guard-b.sh)"
got_a="$(jq -r '.pins["scripts/hooks/hook-a.sh"]' "$PIN_FILE" 2>/dev/null)"
got_b="$(jq -r '.pins["scripts/guardrails/guard-b.sh"]' "$PIN_FILE" 2>/dev/null)"

if [ "$got_a" = "$expected_a" ]; then
  ok "hooks/hook-a.sh pinned to its git blob sha"
else
  bad "hooks/hook-a.sh pin mismatch: got $got_a expected $expected_a"
fi
if [ "$got_b" = "$expected_b" ]; then
  ok "guardrails/guard-b.sh pinned to its git blob sha"
else
  bad "guardrails/guard-b.sh pin mismatch: got $got_b expected $expected_b"
fi

# No CLAUDE_PROJECT_DIR / no session_id / no git repo -> no pin file, exit 0.
rm -rf "$OUT_DIR"
printf '{"source":"startup"}' | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" bash "$SCRIPT"
rc2=$?
if [ "$rc2" -eq 0 ] && [ ! -d "$OUT_DIR" ]; then
  ok "missing session_id writes nothing and still exits 0"
else
  bad "missing session_id: rc=$rc2 out_dir_created=$( [ -d "$OUT_DIR" ] && echo yes || echo no )"
fi

NONGIT="$T/nongit"
mkdir -p "$NONGIT/scripts/hooks"
printf 'echo x\n' > "$NONGIT/scripts/hooks/x.sh"
printf '{"session_id":"test-session-2"}' | CLAUDE_PROJECT_DIR="$NONGIT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" bash "$SCRIPT"
rc3=$?
if [ "$rc3" -eq 0 ] && [ ! -f "$OUT_DIR/test-session-2.json" ]; then
  ok "non-git project dir writes nothing and still exits 0"
else
  bad "non-git project dir: rc=$rc3 pin_present=$( [ -f "$OUT_DIR/test-session-2.json" ] && echo yes || echo no )"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
