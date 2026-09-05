#!/usr/bin/env bash
# Cadence-scoped PreToolUse Bash DENY hook for run_in_background (HIMMEL-1682 S2b).
#
# WHY: unattended cadence legs have twice elected to background a slow step
# ("find is slow on this filesystem", "waiting for the media fetch") and then
# wait for a task notification that an unattended run can never act on — parking
# forever and recording a vacuous "complete". Decisive evidence (HIMMEL-1682): a
# 15,373-file vault scan takes ~2s on this filesystem, so the "slow" excuse was a
# confabulation; the parking is a BEHAVIOURAL default (the session electing to
# background work), not a genuine performance problem. This is the second+ drift
# of "workers park on background work", so per house doctrine (structural >
# instructional) it escalates to a structural control, not another prompt line.
#
# This hook DENIES any Bash call made with run_in_background:true in a cadence
# session, and the deny reason redirects the model to the synchronous foreground
# path IN THE SAME TURN — converting a silent park into a completed run.
#
# CONTRACT:
#   * tool_name Bash + tool_input.run_in_background == true  -> exit 2 (deny),
#     stderr shown to the model naming the foreground alternative.
#   * Everything else -> exit 0, no decision (foreground commands, non-Bash
#     tools, missing jq, unparseable input). FAIL-OPEN on parse: this is a
#     behaviour-shaping hook, not a security floor, so a parse hiccup must NOT
#     block the whole cadence.
#   * exit 2 is the deny form whose precedence over a hook "allow" is guaranteed
#     (HIMMEL-203: "a deny rule and an exit-2 hook WIN over a hook allow"), so a
#     backgrounded command that auto-approve-safe-bash would otherwise grant is
#     still denied. Wired FIRST in cadence-settings.json for clarity.
#   * Wired ONLY in cadence-settings.json (--settings for cadence runs), so
#     interactive sessions keep their run_in_background capability.
#
# No bypass env var — there is nothing legitimate to bypass in a cadence run
# (cadence legs are foreground-by-design). To DISABLE, remove from
# cadence-settings.json. bash 3.2-compatible.
set -uo pipefail

# --- Fail open on anything we cannot evaluate ---
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0

# tool_name is a top-level field; run_in_background is a tool_input sibling of
# the command. jq -e makes the boolean test exact (true only, not "true"/1/yes).
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
[ "$tool" = "Bash" ] || exit 0

if printf '%s' "$input" | jq -e '.tool_input.run_in_background == true' >/dev/null 2>&1; then
    echo "cadence-deny-background: run_in_background is denied in a cadence session" \
         "(HIMMEL-1682) — unattended runs cannot act on a background-task notification." \
         "Re-run this command synchronously in the FOREGROUND (run_in_background=false);" \
         "cadence legs are foreground-by-design." >&2
    exit 2
fi

exit 0
