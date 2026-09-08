#!/usr/bin/env bash
# session-name.sh — resolve the running Claude Code session's `-n` name from
# inside a hook or tool subprocess (HIMMEL-2788).
#
# PLATFORM GUARD: no .ps1 twin, by design, not oversight — this reads
# /proc/<pid>/cmdline, a Linux-only seam (no /proc on macOS/Windows).
#
# There is no CLAUDE_SESSION_NAME env var in this codebase (checked: no hit
# anywhere in scripts/ or docs/internals/). What DOES exist: claude exports
# CLAUDE_PID into every tool subprocess it spawns (HIMMEL-2514, see
# scripts/handover/headed-arm.sh), and the launched `claude` process's own
# argv carries `-n <name>` when the session was named. /proc/<pid>/cmdline is
# therefore the reliable seam — Linux only, matching the claudex lane, which
# is konsole/Linux-only today (HIMMEL-2788 leg doc fact 7). Platforms without
# /proc (macOS, Windows) get empty output here, never a wrong name — callers
# must treat that as "unresolvable" and fail open, not as an error.
#
# Usage: source this file, call `current_session_name`. Prints the resolved
# name on stdout and returns 0; prints nothing and returns 1 when
# unresolvable (no CLAUDE_PID, no /proc, no `-n` flag in argv, or the name
# fails validation).
#
# Validation is load-bearing, not cosmetic: callers build a filesystem path
# from this value (<handover root>/inbox/<name>.md) — a name containing '/',
# '..' or whitespace must never be allowed to traverse outside inbox/.
current_session_name() {
    local pid="${CLAUDE_PID:-}"
    [ -n "$pid" ] || return 1

    # Test seam ONLY: production never sets SESSION_NAME_CMDLINE_FILE, so this
    # always resolves to the real /proc path. A test fixture can't fabricate a
    # NUL-delimited /proc/<pid>/cmdline on demand for an arbitrary pid, so
    # test-session-name.sh points this at a hand-built fixture file instead.
    local cmdline_file="${SESSION_NAME_CMDLINE_FILE:-/proc/$pid/cmdline}"
    [ -r "$cmdline_file" ] || return 1

    local name="" tok prev=""
    while IFS= read -r -d '' tok; do
        if [ "$prev" = "-n" ]; then
            name="$tok"
            break
        fi
        prev="$tok"
    done < "$cmdline_file" 2>/dev/null

    [ -n "$name" ] || return 1
    case "$name" in
        */*|*..*|*[[:space:]]*) return 1 ;;
    esac

    printf '%s\n' "$name"
}
