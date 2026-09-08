#!/usr/bin/env bash
# claudex-inbox-hook.sh — PostToolUse hook, matcher `*` (HIMMEL-2788).
#
# PLATFORM GUARD: no .ps1 twin, by design, not oversight. The claudex lane
# this hook serves (scripts/claude-codex, /proc/$CLAUDE_PID/cmdline session-
# name recovery) is Linux-only — there is no Windows-side claudex leg to fire
# for.
#
# WHY: claudex legs (GPT-6 Astra via scripts/claude-codex,
# CLAUDE_CONFIG_DIR=~/.claude-codex) cannot ListAgents/SendMessage a native
# session, so a console ruling reached them only via a handover-doc bullet
# (never re-read by a running session) plus an operator paste. This hook
# delivers a per-session file inbox (<handover root>/inbox/<name>.md,
# scripts/handover/console-kit/inbox-send.sh appends to it) as
# hookSpecificOutput.additionalContext, so the next tool result already
# carries any ruling the console wrote — no paste, no lost rulings.
#
# Cost model (HIMMEL-2767): fires on EVERY tool call in EVERY session,
# native ones included. The real work is scripts/lib/claudex-inbox.sh's
# inbox_with_lock, which serializes cursor checks when an inbox exists — see
# its header. This script adds only cheap guards on top and never starts jq
# unless there is actually new content to format.
#
# Fail OPEN, always exit 0: a broken inbox (missing handover root, unreadable
# session name, no jq) must never block a tool call — this is delivery, not
# a security fence (scripts/hooks/CLAUDE.md's fail-open-vs-closed rule).
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

command -v jq >/dev/null 2>&1 || exit 0

# shellcheck disable=SC2317,SC2329 # Callback invoked by inbox_with_lock.
deliver_inbox() {
    inbox_peek "$1" || return 1
    if [ -n "$inbox_bullets" ]; then
        jq -nc --arg ctx "$inbox_bullets" \
            '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:("Claudex inbox — console ruling(s) delivered, no operator paste needed:\n" + $ctx)}}' \
            2>/dev/null || return 1
    fi
    inbox_commit
}

inbox_with_lock "$name" deliver_inbox 2>/dev/null
exit 0
