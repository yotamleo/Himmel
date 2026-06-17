#!/usr/bin/env bash
# Smoke test for scripts/plugin-test.sh (HIMMEL-366).
# Structural arg-handling checks + one end-to-end run that proves the helper
# self-bootstraps a plugin's deps and reaches a GREEN baseline.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/plugin-test.sh"
fails=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

# 1. Syntax.
if bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "syntax"; fi

# 2. No args -> usage exit 2.
bash "$SCRIPT" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "no args -> exit 2"; else bad "no args exited $rc (want 2)"; fi

# 3. Unknown plugin -> exit 2.
bash "$SCRIPT" definitely-not-a-plugin >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "unknown plugin -> exit 2"; else bad "unknown plugin exited $rc (want 2)"; fi

# 4. A plugin dir with no package.json -> exit 2 (CLAUDE.md is a real dir-less
#    case: the marketplace/plugins/ root itself has no package.json).
bash "$SCRIPT" . >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "no package.json -> exit 2"; else bad "no-package.json exited $rc (want 2)"; fi

# 5. End-to-end: run against luna-correlate (declares @modelcontextprotocol/sdk
#    + a test suite). The helper must install deps and exit 0 with a green run.
#    This is the headline property — a fresh worktree reaches GREEN in one shot.
if [ -f "$ROOT/marketplace/plugins/luna-correlate/package.json" ]; then
  out="$(bash "$SCRIPT" luna-correlate 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then ok "luna-correlate end-to-end exits 0 (green baseline)"; else bad "luna-correlate exited $rc; output tail: $(printf '%s' "$out" | tail -5)"; fi
  if printf '%s' "$out" | grep -q "0 fail"; then ok "luna-correlate test run reports 0 fail"; else bad "no '0 fail' line in output"; fi
else
  ok "luna-correlate absent — skipping end-to-end (no plugin to test)"
fi

echo ""
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
