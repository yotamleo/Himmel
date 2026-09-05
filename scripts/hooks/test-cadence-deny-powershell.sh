#!/usr/bin/env bash
# Smoke test for scripts/hooks/cadence-deny-powershell.sh (HIMMEL-1973).
#
# Usage: bash scripts/hooks/test-cadence-deny-powershell.sh
#
# Contract under test:
#   * tool_name PowerShell -> exit 2 (deny) + a stderr reason naming both the
#     Bash alternative (so the model retries on the granted path in the same
#     turn) and the CADENCE_POWERSHELL_OK=1 operator carve-out.
#   * CADENCE_POWERSHELL_OK=1 -> exit 0, no decision, no output: the bypass
#     WITHDRAWS the hook, it never grants. Only that exact value opts out.
#   * a payload that PARSES and names a different tool -> exit 0, no decision.
#   * FAIL-CLOSED on anything unevaluable (jq missing, empty or unparseable
#     stdin) -> still deny; the PowerShell matcher is independent evidence of
#     the tool, and what this hook guards is an unguarded shell.
#
# Exit codes: 0 all cases passed, 1 at least one failed.
set -uo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# Invoked as `bash "$HOOK"` throughout, so no exec bit is needed — and setting
# one would dirty the working tree on a filesystem that tracks the mode.
HOOK="$(cd "$(dirname "$0")" && pwd)/cadence-deny-powershell.sh"

FAILED=0

# The exact 2026-08-20 04:00 health-leg invocation, verbatim from the session
# transcript — the shape that parked the leg.
PWSH_CMD='python "C:\Users\<user>\Documents\github\himmel\marketplace\plugins\obsidian-triage\skills\vault-lint\vault_lint.py" "C:\Users\<user>\Documents\luna"'

# Runs the hook, echoes "<rc>|<stderr>". The env is scrubbed of the bypass so a
# operator shell that happens to export it cannot turn the deny cases green.
run_hook() {
    local input="$1" err rc
    err=$(printf '%s' "$input" | CADENCE_POWERSHELL_OK='' bash "$HOOK" 2>&1 >/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$err"
}

# Same, with the documented operator carve-out set.
run_hook_bypass() {
    local input="$1" err rc
    err=$(printf '%s' "$input" | CADENCE_POWERSHELL_OK=1 bash "$HOOK" 2>&1 >/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$err"
}

assert() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label ($actual)"
    else
        echo "FAIL $label — expected $expected, got $actual"
        FAILED=$((FAILED + 1))
    fi
}

j_tool() { printf '{"tool_name":%s,"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)"; }

# --- DENY: the PowerShell tool, whatever it carries ---
res=$(run_hook "$(j_tool PowerShell "$PWSH_CMD")")
assert "08-20 health-leg engine call via PowerShell -> deny" 2 "${res%%|*}"
if grepq "${res#*|}" -F 'Bash tool'; then
    echo "PASS deny reason redirects to the Bash tool"
else
    echo "FAIL deny reason does not name the Bash tool — got: ${res#*|}"
    FAILED=$((FAILED + 1))
fi
# Repo hook policy: every deny names its documented single-run bypass in the
# message it shows the model (CodeRabbit, PR #1766).
if grepq "${res#*|}" -F 'CADENCE_POWERSHELL_OK=1'; then
    echo "PASS deny reason names the bypass variable"
else
    echo "FAIL deny reason does not name CADENCE_POWERSHELL_OK=1 — got: ${res#*|}"
    FAILED=$((FAILED + 1))
fi
assert "harmless PowerShell command -> still denied" 2 "$(res=$(run_hook "$(j_tool PowerShell 'Get-ChildItem')"); printf '%s' "${res%%|*}")"

# --- BYPASS: CADENCE_POWERSHELL_OK=1 withdraws the hook (no decision) ---
bres=$(run_hook_bypass "$(j_tool PowerShell "$PWSH_CMD")")
assert "CADENCE_POWERSHELL_OK=1 -> no decision" 0 "${bres%%|*}"
if [ -z "${bres#*|}" ]; then
    echo "PASS bypass emits no deny message"
else
    echo "FAIL bypass still wrote to stderr — got: ${bres#*|}"
    FAILED=$((FAILED + 1))
fi
# The bypass must WITHDRAW the hook, never grant: the call falls through to the
# normal permission flow, so there must be no allow decision on stdout either.
bout=$(printf '%s' "$(j_tool PowerShell "$PWSH_CMD")" | CADENCE_POWERSHELL_OK=1 bash "$HOOK" 2>/dev/null)
if [ -z "$bout" ]; then
    echo "PASS bypass emits no stdout decision (withdraws, does not grant)"
else
    echo "FAIL bypass wrote a decision to stdout — got: $bout"
    FAILED=$((FAILED + 1))
fi
# Only the exact documented value opts out — a stray truthy-looking value must
# not silently disable the guardrail.
rc_with_ok() {
    printf '%s' "$(j_tool PowerShell "$PWSH_CMD")" | CADENCE_POWERSHELL_OK="$1" bash "$HOOK" >/dev/null 2>&1
    printf '%s' "$?"
}
assert "CADENCE_POWERSHELL_OK=0 -> still denied"    2 "$(rc_with_ok 0)"
assert "CADENCE_POWERSHELL_OK=true -> still denied" 2 "$(rc_with_ok true)"
assert "CADENCE_POWERSHELL_OK= (empty) -> still denied" 2 "$(rc_with_ok "")"

# --- PASS: a payload that POSITIVELY names another tool bows out ---
# This read is defence-in-depth against a future widened matcher; the matcher
# itself is what scopes the hook.
assert "Bash tool -> no decision"  0 "$(res=$(run_hook "$(j_tool Bash "$PWSH_CMD")"); printf '%s' "${res%%|*}")"
assert "Read tool -> no decision"  0 "$(res=$(run_hook "$(j_tool Read 'x')"); printf '%s' "${res%%|*}")"
# Substring/prefix twins must not be caught by a sloppy match.
assert "PowerShellFoo tool -> no decision" 0 "$(res=$(run_hook "$(j_tool PowerShellFoo 'x')"); printf '%s' "${res%%|*}")"

# --- FAIL-CLOSED: anything we cannot evaluate still denies (panel r4) ---
# The matcher is independent evidence the tool IS PowerShell, and what this
# hook guards is an unguarded shell — failing open re-opens the very approval
# stall the control exists to prevent.
assert "empty input -> denied (fail-closed)"      2 "$(res=$(run_hook ""); printf '%s' "${res%%|*}")"
assert "unparseable input -> denied (fail-closed)" 2 "$(res=$(run_hook "not json"); printf '%s' "${res%%|*}")"
# jq unavailable: rename the probed binary in a temp copy of the hook — the
# sed-a-temp-copy seam the sibling approve-engines suite uses for its
# empty-root and cygpath-less cases. Isolates THIS branch on every platform;
# an emptied PATH would instead take out `cat` and pass for the wrong reason.
NOJQ_HOOK=$(mktemp "${TMPDIR:-/tmp}/cadence-deny-powershell.XXXXXX")
trap 'rm -f "$NOJQ_HOOK"' EXIT
sed 's/command -v jq /command -v jq__absent__ /' "$HOOK" > "$NOJQ_HOOK"
if grep -q 'jq__absent__' "$NOJQ_HOOK"; then
    printf '%s' "$(j_tool PowerShell "$PWSH_CMD")" | bash "$NOJQ_HOOK" >/dev/null 2>&1
    assert "jq unavailable -> denied (fail-closed)" 2 "$?"
else
    echo "FAIL jq-absent fixture did not patch the hook — the probe line changed shape" >&2
    FAILED=$((FAILED + 1))
fi

# The hook must NEVER emit an allow decision — it is a deny-only control.
out=$(printf '%s' "$(j_tool PowerShell "$PWSH_CMD")" | bash "$HOOK" 2>/dev/null)
if grepq "$out" '"permissionDecision"'; then
    echo "FAIL hook emitted a permission decision on stdout — it must only deny via exit 2"
    FAILED=$((FAILED + 1))
else
    echo "PASS hook emits no stdout permission decision"
fi

if [ "$FAILED" -eq 0 ]; then
    echo "OK cadence-deny-powershell: all cases passed"
    exit 0
fi
echo "ERR cadence-deny-powershell: $FAILED case(s) failed" >&2
exit 1
