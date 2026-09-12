#!/usr/bin/env bash
# Smoke test for scripts/plugin-eval-preflight.sh (HIMMEL-2931). Non-billing:
# never invokes the real `claude plugin eval`, only ever a PATH-stub `claude`.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure bash + coreutils; no .ps1 twin needed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/plugin-eval-preflight.sh"
fails=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

if bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "syntax"; fi

TMP=$(mktemp -d) || { echo "FAIL - mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# T1: bank refuses (SKIPPED-BANK) — the script must exit 1 WITHOUT ever
# invoking `claude` at all (bank check gates before the version check).
# A fake lib/bank-preflight.sh forces the refusal deterministically; a
# failing PATH-stub `claude` proves it was never reached — if the script
# called it, the stub's own failure would surface as a DIFFERENT error
# than the expected bank-refusal message.
mkdir -p "$TMP/t1/scripts/lib" "$TMP/t1/bin"
cp "$SCRIPT" "$TMP/t1/scripts/plugin-eval-preflight.sh"
cat > "$TMP/t1/scripts/lib/bank-preflight.sh" <<'EOF'
#!/usr/bin/env bash
echo "SKIPPED-BANK"
exit 0
EOF
chmod +x "$TMP/t1/scripts/lib/bank-preflight.sh"
cat > "$TMP/t1/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude: should never have been invoked" >&2
exit 1
EOF
chmod +x "$TMP/t1/bin/claude"
out=$(PATH="$TMP/t1/bin:$PATH" bash "$TMP/t1/scripts/plugin-eval-preflight.sh" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && grep -q "SKIPPED-BANK" <<< "$out" && ! grep -q "should never have been invoked" <<< "$out"; then
    ok "T1 bank refusal (SKIPPED-BANK) exits 1, claude never invoked"
else
    bad "T1 bank refusal — rc=$rc out=$out"
fi

# T2: bank proceeds — a deterministic PROCEED stub, same pattern as T1, so
# this non-billing test never depends on the REAL bank's live state (it did
# fail this way once: the ambient bank hit its 85% cap mid-session and T2/T3
# both read the real scripts/lib/bank-preflight.sh, which returned
# SKIPPED-BANK instead of PROCEED) — but claude reports a version below the
# 2.1.269 floor, so the script must refuse.
mkdir -p "$TMP/t2/scripts/lib" "$TMP/t2/bin"
cp "$SCRIPT" "$TMP/t2/scripts/plugin-eval-preflight.sh"
cat > "$TMP/t2/scripts/lib/bank-preflight.sh" <<'EOF'
#!/usr/bin/env bash
echo "PROCEED"
exit 0
EOF
chmod +x "$TMP/t2/scripts/lib/bank-preflight.sh"
cat > "$TMP/t2/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
    echo "2.1.268 (Claude Code)"
    exit 0
fi
echo "claude: unexpected invocation $*" >&2
exit 1
EOF
chmod +x "$TMP/t2/bin/claude"
out=$(PATH="$TMP/t2/bin:$PATH" bash "$TMP/t2/scripts/plugin-eval-preflight.sh" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && grep -q "2.1.268" <<< "$out" && grep -q "2.1.269" <<< "$out"; then
    ok "T2 below-floor version (2.1.268) refuses"
else
    bad "T2 below-floor version — rc=$rc out=$out"
fi

# T3: bank proceeds (same deterministic stub as T2), claude reports a
# version at the floor — the script must PROCEED (still non-billing: PROCEED
# means "safe to run", it does not itself run `claude plugin eval`).
mkdir -p "$TMP/t3/scripts/lib" "$TMP/t3/bin"
cp "$SCRIPT" "$TMP/t3/scripts/plugin-eval-preflight.sh"
cat > "$TMP/t3/scripts/lib/bank-preflight.sh" <<'EOF'
#!/usr/bin/env bash
echo "PROCEED"
exit 0
EOF
chmod +x "$TMP/t3/scripts/lib/bank-preflight.sh"
cat > "$TMP/t3/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
    echo "2.1.269 (Claude Code)"
    exit 0
fi
echo "claude: unexpected invocation $*" >&2
exit 1
EOF
chmod +x "$TMP/t3/bin/claude"
out=$(PATH="$TMP/t3/bin:$PATH" bash "$TMP/t3/scripts/plugin-eval-preflight.sh" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && grep -q "PROCEED" <<< "$out"; then
    ok "T3 at-floor version (2.1.269) proceeds"
else
    bad "T3 at-floor version — rc=$rc out=$out"
fi

if [ "$fails" -eq 0 ]; then
    echo "PASS - all plugin-eval-preflight checks"
    exit 0
else
    echo "FAIL - $fails plugin-eval-preflight check(s) failed"
    exit 1
fi
