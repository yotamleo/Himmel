#!/usr/bin/env bash
# Cadence-scoped PreToolUse DENY hook for the PowerShell tool (HIMMEL-1973).
#
# WHY: the whole cadence guardrail stack is wired `"matcher": "Bash"` and each
# hook self-checks `tool_name == "Bash"` — cadence-deny-background.sh,
# cadence-approve-engines.sh and auto-approve-safe-bash.sh alike. The PowerShell
# tool is therefore an UNGUARDED second shell in a cadence session: no
# background deny, no enumerated-engine grant, no safe-command auto-approve.
#
# Decisive evidence (HIMMEL-1973): the HIMMEL-Pipeline-Health leg emitted the
# vault-lint engine call through the PowerShell tool on 2026-08-20 04:00 —
#   python "C:\...\vault-lint\vault_lint.py" "C:\Users\<user>\Documents\luna"
# — a command cadence-approve-engines.sh grants byte-for-byte when it arrives as
# a Bash call (it did on 08-19, and that night's leg completed). Because it
# arrived as PowerShell, no hook saw it, the model got an approval-required
# reply, read it as "the operator must authorise this", and parked the leg with
# nobody awake to answer. The tool choice is not stable across nights, so this
# is a shape the cadence hits at random — a structural control, not a prompt
# line, is what closes it (house doctrine: structural > instructional).
#
# The deny reason redirects the model to the Bash tool IN THE SAME TURN, where
# the engine grant already lives — converting a silent park into a completed
# run, exactly as cadence-deny-background.sh does for backgrounded commands.
#
# CONTRACT (mirrors cadence-deny-background.sh):
#   * tool_name PowerShell -> exit 2 (deny), stderr shown to the model naming
#     the Bash alternative.
#   * A payload that PARSES and names a different tool -> exit 0, no decision.
#     That read is defence-in-depth only: the `"matcher": "PowerShell"` block in
#     cadence-settings.json is what scopes this hook, and the check exists so a
#     future widened matcher cannot turn this into a blanket deny.
#   * FAIL-CLOSED when we cannot evaluate (jq missing, unparseable/empty input)
#     -> still deny. Unlike its two siblings, this hook fails closed: the thing
#     it guards is an UNGUARDED shell (no background deny, no engine grant, no
#     safe-command auto-approve reaches a PowerShell call), and the matcher is
#     independent evidence that the tool IS PowerShell. Failing open here would
#     re-open exactly the unattended approval stall this control exists to
#     prevent. Denying costs nothing: no cadence leg needs the tool.
#   * NEVER allows. exit 2 is the deny form whose precedence is guaranteed
#     (HIMMEL-203), so nothing downstream can re-grant a PowerShell call.
#   * CADENCE_POWERSHELL_OK=1 -> exit 0, no decision (see BYPASS below).
#   * Wired ONLY in cadence-settings.json (--settings for cadence runs), so
#     interactive sessions keep the PowerShell tool. On POSIX hosts the tool
#     does not exist and the matcher simply never fires.
#
# BYPASS: CADENCE_POWERSHELL_OK=1 — a single-run operator carve-out, set in the
# shell that LAUNCHES Claude Code (`CADENCE_POWERSHELL_OK=1 claude …`). A
# per-call prefix does NOT work: Claude cannot inject env vars into hook
# processes. The bypass exits 0 with NO decision, so the call still goes through
# the normal permission flow — it withdraws this hook, it does not grant
# anything. To disable the hook outright, remove it from cadence-settings.json.
# bash 3.2-compatible.
set -uo pipefail

# --- Bow out ONLY when the payload positively names a different tool ---
# Anything we cannot evaluate (no jq, empty or unparseable stdin) falls through
# to the deny: the matcher already told us this is a PowerShell call.
input=$(cat 2>/dev/null || true)
if [ -n "$input" ] && command -v jq >/dev/null 2>&1; then
    tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
    if [ -n "$tool" ] && [ "$tool" != "PowerShell" ]; then
        exit 0
    fi
fi

# Operator carve-out — see BYPASS in the header. No decision, not an allow.
if [ "${CADENCE_POWERSHELL_OK:-}" = "1" ]; then
    exit 0
fi

echo "cadence-deny-powershell: the PowerShell tool is denied in a cadence session" \
     "(HIMMEL-1973) — it bypasses every cadence guardrail, including the" \
     "enumerated-engine auto-approval, so a PowerShell call stalls on an" \
     "approval nobody is awake to give. This is NOT an operator-approval" \
     "situation: re-issue the command with the Bash tool (Git Bash) in the" \
     "foreground — verbatim if it is already shell-agnostic (the cadence's" \
     "engine calls are), otherwise translated to the equivalent Bash" \
     "invocation. Operator carve-out:" \
     "CADENCE_POWERSHELL_OK=1 must be set in the shell that LAUNCHES claude" \
     "(a per-call prefix does NOT work)." >&2
exit 2
