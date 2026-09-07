#!/usr/bin/env bash
# shellcheck shell=sh
# run-node.sh — runtime node launcher for hook commands. Resolves node every
# call (surviving PATH-less GUI launches + node upgrades) and execs it.
#
#   . run-node.sh <script.js> [args...]     # how every wired hook invokes it
#   bash run-node.sh <script.js> [args...]  # direct execution also works
#
# Hook commands route through this instead of a
# bare `node` or a setup-time-frozen absolute path (see resolve-node.sh WHY).
#
# POSIX sh ONLY — the `shell=sh` directive above is load-bearing, not cosmetic.
# Claude Code runs hook commands through /bin/sh, which is dash on Debian and
# Ubuntu, so the bash shebang never applies on the sourced path. In particular
# NO ${BASH_SOURCE[0]}: dash rejects the array subscript as "Bad substitution",
# which left the script dir empty, made the `.` below fail, and exited 2 — a
# PreToolUse DENY on EVERY tool call, on every Debian/Ubuntu box (HIMMEL-2692).
#
# FAIL-OPEN: if no node is found, write ONE breadcrumb line to
# ${CLAUDE_DIR:-$HOME/.claude}/himmel-node.log and exit 0 with NOTHING on
# stdout/stderr — converting the old per-session "node: command not found" hook
# error (which Claude Code surfaces) into actual silence. `/himmel-doctor` C1 is
# what surfaces a genuinely-missing node.
set -u

# Locate the sibling resolve-node.sh WITHOUT introspecting this file's own path.
# When this file is SOURCED, $0 is the CALLER's shell — measured as literally
# `sh` under a dash-family /bin/sh — not this file, and the bash-only
# ${BASH_SOURCE[0]} does not exist there at all.
#
# $0 is therefore trusted ONLY when it actually names this file, i.e. a direct
# `bash run-node.sh …` run. That guard is a security boundary, not a tidiness
# one: `dirname sh` is `.`, so an unguarded $0 candidate would resolve to the
# CWD — which for a hook is the repo under review — and source whatever
# `./resolve-node.sh` that repo happened to ship, as shell code, on every tool
# call (codex-2 on the HIMMEL-2692 panel).
#
# Otherwise use the root the call site itself exported, and ONLY that one. The
# two lanes are MUTUALLY EXCLUSIVE, deliberately — this is not a fallback chain
# (HIMMEL-2702). CLAUDE_PROJECT_DIR is the repo UNDER REVIEW, and resolve-node.sh
# is sourced, not executed, so a resolver found there runs that repo's shell code
# in the hook's own shell. A chain that tried the plugin root and then fell
# through to the project root would do exactly that whenever a plugin install is
# damaged or mid-upgrade: an adopter repo shipping scripts/lib/resolve-node.sh
# would be sourced, and a hostile one could plant it. So when CLAUDE_PLUGIN_ROOT
# is set we are the plugin copy and the plugin root is the ONLY trusted location;
# a damaged plugin install then finds nothing and takes the FAIL-OPEN path below
# — one breadcrumb line and exit 0 — which is the right outcome. A missing
# resolver must degrade to silence, never to sourcing a substitute from a
# different trust domain.
#
# Candidates are tested with -r, not -f: `.` on an existing-but-unreadable file
# is fatal in a non-interactive POSIX shell, which is the very DENY this file
# exists to stop, so an unreadable candidate must reach the fail-open path rather
# than be sourced (codex-3). The two copies of this file are byte-identical
# (enforced by scripts/hooks/test-plugin-hook-bash-wiring.sh), so the lane is
# selected by the ENVIRONMENT, not by which copy is running — one body cannot
# know which of the two it is.
_script_dir=''
case "$0" in
    */run-node.sh|run-node.sh)
        # Direct execution: $0 IS this file, so its directory is authoritative.
        _cand="$(dirname "$0")"
        if [ -r "$_cand/resolve-node.sh" ]; then _script_dir="$_cand"; fi
        ;;
esac
if [ -z "$_script_dir" ]; then
    if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
        # Plugin lane: the plugin root, and nothing else.
        if [ -r "${CLAUDE_PLUGIN_ROOT}/hooks/resolve-node.sh" ]; then
            _script_dir="${CLAUDE_PLUGIN_ROOT}/hooks"
        fi
    elif [ -r "${CLAUDE_PROJECT_DIR:-}/scripts/lib/resolve-node.sh" ]; then
        # Project lane: reached only when no plugin root was exported at all.
        _script_dir="${CLAUDE_PROJECT_DIR}/scripts/lib"
    fi
fi

_node=''
if [ -n "$_script_dir" ]; then
    # shellcheck source=/dev/null
    . "$_script_dir/resolve-node.sh"
    _node="$(resolve_node)" || _node=''
fi
if [ -n "$_node" ]; then
    exec "$_node" "$@"
fi

# No node: silent fail-open + a breadcrumb for the doctor / a curious operator.
_log_dir="${CLAUDE_DIR:-${HOME:-.}/.claude}"
mkdir -p "$_log_dir" 2>/dev/null || true
printf '%s node not found; skipped: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo '?')" "$*" \
    >> "$_log_dir/himmel-node.log" 2>/dev/null || true
exit 0
