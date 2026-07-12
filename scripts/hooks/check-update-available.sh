#!/usr/bin/env bash
# check-update-available.sh — SessionStart hook: nudge the operator when the
# himmel checkout is behind its upstream (HIMMEL-413).
#
# WHY this exists: himmel updates (hooks, commands, CLAUDE.md) only land via
# git pull — autoUpdate never covers them (see docs/setup/updating.md). Without
# a session-start nudge the operator may run stale code for days without
# noticing. This hook announces the gap once per throttle interval so the cost
# stays low (one git fetch at most every 4 h per machine).
#
# Fail OPEN on everything: no git repo, no upstream, offline, git error, stat
# error, any other unexpected state → exit 0, empty stdout. Never block.
#
# Throttle model (mirrors auto-arm-on-cap.sh):
#   - State dir: UPDATE_CHECK_STATE_DIR (default /tmp/claude), same as the
#     rest of himmel's tmp state.
#   - Stamp file: <state-dir>/himmel-update-check-last  (mtime = last check).
#   - Interval: UPDATE_CHECK_INTERVAL seconds (default 14400 = 4 h).
#   - IMPORTANT: stamp is written / touch'd BEFORE the network fetch so a
#     hung git fetch never wedges future checks (operator restarts a session,
#     hung job from the previous run holds the interval open).
#
# Env knobs (all optional):
#   UPDATE_CHECK_DISABLE=1           kill switch
#   UPDATE_CHECK_INTERVAL            seconds between checks (default 14400)
#   UPDATE_CHECK_STATE_DIR           state dir override (test seam; default /tmp/claude)
#
# Stdout contract (SessionStart):
#   Exit 0 + any stdout → injected as additional context for Claude.
#   Exit non-zero → blocks the session (we never do this; always exit 0).
#
# Bash 3.2 compatible.

set -euo pipefail

# Always exit clean; never block a session.
trap 'exit 0' ERR

# ─── kill switch ────────────────────────────────────────────────────────────
[ "${UPDATE_CHECK_DISABLE:-0}" = "1" ] && exit 0

# ─── config ─────────────────────────────────────────────────────────────────
STATE_DIR="${UPDATE_CHECK_STATE_DIR:-/tmp/claude}"
INTERVAL="${UPDATE_CHECK_INTERVAL:-14400}"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=14400 ;; esac

STAMP="$STATE_DIR/himmel-update-check-last"

# ─── mtime helper (Bash 3.2 + macOS BSD stat + GNU stat) ────────────────────
# Returns the mtime as epoch seconds, or empty on error.
# Pattern taken from scripts/statusline/bin/statusline.sh.
_mtime() {
    local f="$1" t=""
    # GNU stat
    t=$(stat -c %Y "$f" 2>/dev/null) && printf '%s' "$t" && return
    # BSD stat (macOS)
    t=$(stat -f %m "$f" 2>/dev/null) && printf '%s' "$t" && return
    # date -r fallback (macOS / some BSDs)
    t=$(date -r "$f" +%s 2>/dev/null) && printf '%s' "$t" && return
}

# ─── throttle gate ──────────────────────────────────────────────────────────
now=$(date +%s 2>/dev/null) || exit 0
if [ -f "$STAMP" ]; then
    last=$(_mtime "$STAMP")
    if [ -n "$last" ] && [ $((now - last)) -lt "$INTERVAL" ]; then
        exit 0
    fi
fi

# Write stamp BEFORE network fetch so a hang doesn't wedge future checks.
mkdir -p "$STATE_DIR" 2>/dev/null || true
touch "$STAMP" 2>/dev/null || true

# ─── locate repo root ────────────────────────────────────────────────────────
# Prefer CLAUDE_PROJECT_DIR (set by the harness), fall back to git discovery
# from this script's directory.
ROOT="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$ROOT" ]; then
    ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
fi
[ -d "$ROOT/.git" ] || exit 0

# ─── fetch (quiet; offline / no-remote is a silent no-op) ───────────────────
git -C "$ROOT" fetch --quiet origin 2>/dev/null || exit 0

# ─── upstream branch ─────────────────────────────────────────────────────────
upstream=$(git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || exit 0
[ -n "$upstream" ] || exit 0

# ─── behind count ────────────────────────────────────────────────────────────
behind=$(git -C "$ROOT" rev-list --count "HEAD..$upstream" 2>/dev/null) || exit 0
# Validate: must be a non-negative integer.
case "$behind" in ''|*[!0-9]*) exit 0 ;; esac
[ "$behind" -gt 0 ] || exit 0

# ─── emit nudge ──────────────────────────────────────────────────────────────
cat <<EOF
<system-reminder>
himmel is $behind commit(s) behind $upstream. Run /himmel-update to pull the latest fixes and hooks.
(This check won't repeat for another ${INTERVAL}s.)
</system-reminder>
EOF

exit 0
