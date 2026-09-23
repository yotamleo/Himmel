#!/usr/bin/env bash
# scripts/telegram/console-census.sh - HIMMEL-3510. Thin TSV bridge for
# console-heartbeat-watch.ts's censusSessionAlive(): prints
# pid<TAB>name<TAB>model<TAB>autocompact for every live claude session via
# the same claude_sessions() census tick.sh and ceiling-conformance.sh use
# (scripts/lanes/lib/claude-sessions.sh, real /proc/<pid>/cmdline argv, no
# flattened pgrep -af line) — so "is this console still running" never
# re-derives argv parsing of its own.
#
# CLAUDE_SESSIONS_PROC / CLAUDE_SESSIONS_PGREP (documented in
# claude-sessions.sh) are the same test seams this script inherits; it adds
# none of its own. Exit code is claude_sessions()'s own (0 clean, 3 degraded
# scan, >1 a pgrep-level failure) — callers here treat "name not found in the
# output" and "the census itself failed" the same way (no match), since a
# scan too broken to trust must not manufacture a false "alive".
#
# PLATFORM GUARD: no .ps1 twin, by design — Linux-only (matches
# claude-sessions.sh's /proc dependency). bash 3.2-safe.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lanes/lib/claude-sessions.sh
. "$REPO/scripts/lanes/lib/claude-sessions.sh"
claude_sessions
exit $?
