#!/usr/bin/env bash
# run-node.sh — runtime node launcher for hook commands. Resolves node every
# call (surviving PATH-less GUI launches + node upgrades) and execs it.
#
#   bash run-node.sh <script.js> [args...]
#
# The caveman SessionStart/UserPromptSubmit hooks route through this instead of a
# bare `node` or a setup-time-frozen absolute path (see resolve-node.sh WHY).
#
# FAIL-OPEN: if no node is found, write ONE breadcrumb line to
# ${CLAUDE_DIR:-$HOME/.claude}/himmel-node.log and exit 0 with NOTHING on
# stdout/stderr — converting the old per-session "node: command not found" hook
# error (which Claude Code surfaces) into actual silence. `/himmel-doctor` C1 is
# what surfaces a genuinely-missing node.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/resolve-node.sh"

_node="$(resolve_node)" || _node=""
if [ -n "$_node" ]; then
    exec "$_node" "$@"
fi

# No node: silent fail-open + a breadcrumb for the doctor / a curious operator.
_log_dir="${CLAUDE_DIR:-${HOME:-.}/.claude}"
mkdir -p "$_log_dir" 2>/dev/null || true
printf '%s node not found; skipped: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo '?')" "$*" \
    >> "$_log_dir/himmel-node.log" 2>/dev/null || true
exit 0
