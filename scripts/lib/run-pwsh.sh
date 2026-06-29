#!/usr/bin/env bash
# run-pwsh.sh — runtime PowerShell launcher for hook commands. Resolves pwsh at
# call time and execs `pwsh -NoProfile -File <script.ps1> [args...]`.
#
#   bash run-pwsh.sh <script.ps1> [args...]
#
# WHY: the SessionEnd end-session-wiki hook ships BOTH a pwsh twin and a bash
# twin (Claude Code's `shell` field is an interpreter spec, not a platform
# filter; each twin self-guards so exactly one captures per platform). Wiring
# the pwsh twin as a bare `pwsh -NoProfile -File …` makes EVERY session on a
# host WITHOUT PowerShell (most macOS/Linux) print `pwsh: command not found` —
# the bash twin is what should do the capture there. Routing the pwsh twin
# through this wrapper converts that per-session error into silence: when no
# pwsh is found we write ONE breadcrumb line and exit 0, so the bash twin runs
# and captures unhindered. On a host that DOES have pwsh the wrapper execs it
# and the .ps1's own platform guard decides whether to write (no double-capture).
# Mirrors run-node.sh. `/himmel-doctor` C6 is what surfaces a genuinely-missing
# pwsh that a hook still depends on.
#
# FAIL-OPEN: if no pwsh is found, write ONE breadcrumb line to
# ${CLAUDE_DIR:-$HOME/.claude}/himmel-pwsh.log and exit 0 with NOTHING on
# stdout/stderr — converting the old per-session "pwsh: command not found" hook
# error (which Claude Code surfaces) into actual silence.
set -u

if command -v pwsh >/dev/null 2>&1; then
    exec pwsh -NoProfile -File "$@"
fi

# No pwsh: silent fail-open + a breadcrumb for the doctor / a curious operator.
_log_dir="${CLAUDE_DIR:-${HOME:-.}/.claude}"
mkdir -p "$_log_dir" 2>/dev/null || true
printf '%s pwsh not found; skipped: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo '?')" "$*" \
    >> "$_log_dir/himmel-pwsh.log" 2>/dev/null || true
exit 0
