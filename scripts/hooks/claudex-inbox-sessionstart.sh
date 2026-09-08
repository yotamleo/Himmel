#!/usr/bin/env bash
# claudex-inbox-sessionstart.sh — SessionStart chain member (HIMMEL-2788),
# the "catches up a resumed session" half of the claudex file inbox. See
# claudex-inbox-hook.sh (the PostToolUse half) for the full design note.
#
# PLATFORM GUARD: no .ps1 twin, by design, not oversight — same Linux-only
# claudex lane as claudex-inbox-hook.sh.
#
# SessionStart is a `--lifecycle` chain (scripts/hooks/run-hook-with-bash.js:
# "Claude injects a hook's plain stdout as context ... No JSON merging") —
# unlike the PostToolUse half, this member prints PLAIN TEXT, not a
# hookSpecificOutput envelope (same contract as inject-initiative.sh).
#
# Shares the same cursor file as the PostToolUse hook (both call
# inbox_new_bullets for the same session name), so a bullet is delivered
# exactly once regardless of which event fires first — never twice.
#
# Fail OPEN: a lifecycle member is always advisory (HIMMEL-2003) and this
# script never exits non-zero.
set -uo pipefail

CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
[ -n "$CLAUDE_PROJECT_DIR" ] || exit 0

# shellcheck source=../lib/session-name.sh
. "$CLAUDE_PROJECT_DIR/scripts/lib/session-name.sh" 2>/dev/null || exit 0
# shellcheck source=../lib/handover-path.sh
. "$CLAUDE_PROJECT_DIR/scripts/lib/handover-path.sh" 2>/dev/null || exit 0
# shellcheck source=../lib/claudex-inbox.sh
. "$CLAUDE_PROJECT_DIR/scripts/lib/claudex-inbox.sh" 2>/dev/null || exit 0

name="$(current_session_name 2>/dev/null)" || exit 0
[ -n "$name" ] || exit 0

bullets="$(inbox_new_bullets "$name" 2>/dev/null)"
[ -n "$bullets" ] || exit 0

printf 'Claudex inbox — console ruling(s) delivered on resume, no operator paste needed:\n%s\n' "$bullets"
exit 0
