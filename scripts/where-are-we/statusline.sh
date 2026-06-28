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
# Fail-open: a missing/erroring base or segment never errors the bar. The segment
# is `timeout`-bounded (it does one node spawn) so a hung child degrades to
# nothing-extra rather than freezing the render.
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

# Base bar verbatim. Its exit code is IGNORED by design (fail-open). Command
# substitution already strips trailing newlines; the `%$'\n'` is belt-and-braces
# so a future upstream trailing newline still yields a single separator below.
base="$(printf '%s' "$input" | bash "$BASE" 2>/dev/null || true)"
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
    # Bound the segment with GNU `timeout` or macOS coreutils `gtimeout`. If
    # neither exists the segment still self-bounds its one node spawn (C1), so
    # the unguarded fallback is safe.
    seg_to=""
    if command -v timeout >/dev/null 2>&1; then seg_to="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then seg_to="gtimeout"; fi
    extra=""
    if [ -n "$seg_to" ]; then
        extra="$(printf '%s' "$input" | "$seg_to" "${HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT:-5}" bash "$SEG" 2>/dev/null || true)"
    else
        extra="$(printf '%s' "$input" | bash "$SEG" 2>/dev/null || true)"
    fi
    [ -n "$extra" ] && printf '\n%s' "$extra"
fi

exit 0
