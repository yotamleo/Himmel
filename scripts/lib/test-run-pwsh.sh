#!/usr/bin/env bash
# test-run-pwsh.sh — hermetic smoke for scripts/lib/run-pwsh.sh (HIMMEL-611).
# Verifies the pwsh-absent guard (silent fail-open + breadcrumb) and the
# pwsh-present exec path. Usage: bash scripts/lib/test-run-pwsh.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
WRAP="$SELF_DIR/run-pwsh.sh"
[ -f "$WRAP" ] || { echo "FAIL: $WRAP not found"; exit 1; }

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# A PATH built from the REAL dirs of the tools the wrapper needs (date/mkdir/…).
# Using real dirs keeps bash + its MINGW DLLs resolvable (a symlink-only dir
# would break `bash` on Git Bash); pwsh lives elsewhere so it stays excluded.
TP="$(for t in bash sh date mkdir cat grep ln chmod; do
        d="$(command -v "$t" 2>/dev/null)" && dirname "$d"
      done | sort -u | tr '\n' ':')"

# ── Case 1: pwsh absent → exit 0, silent, breadcrumb logged ──────────────────
if PATH="$TP" bash -c '! command -v pwsh >/dev/null 2>&1' 2>/dev/null; then
    t="$(mktemp -d)"
    out="$(PATH="$TP" CLAUDE_DIR="$t/claude" bash "$WRAP" "/some/end-session-wiki.ps1" 2>"$t/err")"; rc=$?
    err="$(cat "$t/err")"
    if [ "$rc" -eq 0 ]; then pass "pwsh absent -> exit 0"; else fail "pwsh absent -> exit $rc"; fi
    if [ -z "$out" ] && [ -z "$err" ]; then pass "pwsh absent -> no stdout/stderr"; else fail "pwsh absent -> out='$out' err='$err'"; fi
    if grep -q 'pwsh not found; skipped: /some/end-session-wiki.ps1' "$t/claude/himmel-pwsh.log" 2>/dev/null; then
        pass "pwsh absent -> breadcrumb written"
    else
        fail "pwsh absent -> no breadcrumb in $t/claude/himmel-pwsh.log"
    fi
    rm -rf "$t"
else
    pass "pwsh-absent cases (skipped: pwsh present under TP on this host)"
fi

# ── Case 2: pwsh present → execs `pwsh -NoProfile -File <script> [args]` ──────
t="$(mktemp -d)"; mkdir -p "$t/bin"
printf '#!/bin/sh\necho "PWSH-ARGS: $*"\n' > "$t/bin/pwsh"; chmod +x "$t/bin/pwsh"
out="$(PATH="$t/bin:$TP" CLAUDE_DIR="$t/claude" bash "$WRAP" "/some/x.ps1" extra 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'PWSH-ARGS: -NoProfile -File /some/x.ps1 extra'; then
    pass "pwsh present -> exec pwsh -NoProfile -File <script> <args>"
else
    fail "pwsh present -> rc=$rc out='$out'"
fi
rm -rf "$t"

if [ "$failures" -ne 0 ]; then echo "FAILED ($failures)"; exit 1; fi
echo "ALL PASS"
