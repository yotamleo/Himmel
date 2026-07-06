#!/usr/bin/env bash
# scripts/where-are-we/statusline.sh — himmel statusLine.command (HIMMEL-538).
# Composes the VENDORED base bar (scripts/statusline/bin/statusline.sh — left
# byte-for-byte UNTOUCHED, so no re-vendor obligation against the upstream fork)
# with ONE where-are-we line (statusline-segment.sh), gated by HIMMEL_WHERE_ARE_WE.
#
# Not a parallel status line: it runs the exact vendored script for the base bar
# and only appends a line. Gate default ON (HIMMEL-556, opt-out): an explicit
# falsy HIMMEL_WHERE_ARE_WE (0|false|off|no) suppresses the segment → adds ZERO
# bytes beyond the base; unset/empty → segment renders.
#
# Fail-open: a missing/erroring base or segment never errors the bar. BOTH the
# base and the segment are `timeout`-bounded (HIMMEL-717) so a hung child (e.g. a
# stalled network read in the base) degrades to nothing-extra rather than
# freezing the render or orphaning this wrapper.
#
# Test seams: HIMMEL_STATUSLINE_BASE / HIMMEL_STATUSLINE_SEGMENT override the
#   composed script paths so the wrapper is testable without the live base
#   (which reads live rate-limits) or a real node spawn.
set -uo pipefail

SD="$(cd "$(dirname "$0")" && pwd)"
BASE="${HIMMEL_STATUSLINE_BASE:-$SD/../statusline/bin/statusline.sh}"
SEG="${HIMMEL_STATUSLINE_SEGMENT:-$SD/statusline-segment.sh}"

# Read the Claude Code JSON once; re-feed via a fresh pipe to each child.
input="$(cat 2>/dev/null || true)"

# Detect GNU `timeout` (or macOS coreutils `gtimeout`) ONCE — used to bound BOTH
# the base and the segment below. Absent → unbounded fallback.
_to=""
if command -v timeout >/dev/null 2>&1; then _to="timeout"
elif command -v gtimeout >/dev/null 2>&1; then _to="gtimeout"; fi

# Base bar verbatim. Its exit code is IGNORED by design (fail-open). Bounded by
# `timeout` (HIMMEL-717): the base reads live rate-limits over the network, and a
# hung read would otherwise block this command-substitution forever, orphaning
# the wrapper on every render (a measured git-bash leak on Windows). Command
# substitution already strips trailing newlines; the `%$'\n'` is belt-and-braces
# so a future upstream trailing newline still yields a single separator below.
if [ -n "$_to" ]; then
    # -k 2: if the base (or a node child it spawned) ignores TERM, escalate to
    # KILL 2s later — otherwise a surviving grandchild keeps this command-
    # substitution pipe open and the wrapper still hangs (HIMMEL-717, Windows).
    base="$(printf '%s' "$input" | "$_to" -k 2 "${HIMMEL_STATUSLINE_BASE_TIMEOUT:-10}" bash "$BASE" 2>/dev/null || true)"
else
    base="$(printf '%s' "$input" | bash "$BASE" 2>/dev/null || true)"
fi
base="${base%$'\n'}"
printf '%s' "$base"

# Default ON (HIMMEL-556): enabled unless HIMMEL_WHERE_ARE_WE is an explicit
# opt-out (0|false|off|no). Unset / empty / any other value → enabled.
_enabled() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        0|false|off|no) return 1 ;;
        *) return 0 ;;
    esac
}

if _enabled "${HIMMEL_WHERE_ARE_WE:-}"; then
    # Bound the segment with the same `timeout` detected above. If neither exists
    # the segment still self-bounds its one node spawn (C1), so the unguarded
    # fallback is safe.
    extra=""
    if [ -n "$_to" ]; then
        extra="$(printf '%s' "$input" | "$_to" "${HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT:-5}" bash "$SEG" 2>/dev/null || true)"
    else
        extra="$(printf '%s' "$input" | bash "$SEG" 2>/dev/null || true)"
    fi
    [ -n "$extra" ] && printf '\n%s' "$extra"
fi

exit 0
