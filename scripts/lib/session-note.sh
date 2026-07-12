#!/usr/bin/env bash
# session-note.sh — Pure markdown renderer for end-session-wiki session notes.
#
# Source this file, then call render_session_note.
#
# render_session_note
#   Reads ALL context from environment variables (no git, no date, no file I/O).
#   Emits the rendered Markdown note to stdout.
#
# Required env vars:
#   REPO_NAME           — git repo name (e.g. "himmel")
#   BRANCH              — current branch (e.g. "feat/luna-backfill")
#   WORKTREE_ABS        — absolute path to worktree (slash-normalised)
#   FILES_COUNT         — integer count of files touched
#   FILES_RAW           — newline-separated list of file paths (may be empty)
#   NOW_ISO             — ISO 8601 UTC timestamp (e.g. "2026-06-20T08:00:00Z")
#   DURATION_MINUTES    — integer duration in minutes
#   SESSION_ID          — session identifier from the SessionEnd payload
#   SOURCE              — capture source ("live" for hook, "claude-backfill" for backfill)
#   CRYSTALLIZED        — "true" if an LLM crystallized the note, else "false" (default false)
#   CRYSTALLIZED_AT     — ISO 8601 timestamp of crystallization, else empty (default empty)
#   LAST_ASSISTANT      — last assistant turn text (may be empty)
#   TRANSCRIPT_READABLE — 1 if transcript was readable, 0 otherwise
#   KEPT_COMMANDS       — filtered command list (may be empty)

render_session_note() {
    # Summary: distil the last assistant turn into its first 4 substantive lines.
    # The opening lines are often throwaway preamble — a reaction to an injected
    # system reminder ("I'll ignore the TaskCreate reminder…") or a bare
    # acknowledgment ("Sure.", "Got it.") — not a distillation (HIMMEL-590 F2).
    # Drop those LEADING meta lines, then take the first few substantive lines.
    # The reminder match requires `reminder` to CO-OCCUR with the injected
    # `TaskCreate` marker (or the literal `system-reminder` tag), so it drops a
    # reaction line ("I'll ignore the TaskCreate reminder…") but NOT a substantive
    # line that merely names one token (e.g. "TaskCreate was wired into the queue"
    # or "Reminder banner implemented"). Case-insensitive + trailing-whitespace-
    # tolerant to stay in lockstep with the PowerShell twin (end-session-wiki.ps1).
    # Crystallization (when claude is available) is the real quality path; this
    # only sharpens the mechanical fallback, and never drops content once a
    # substantive line begins.
    local summary=""
    if [ -n "${LAST_ASSISTANT:-}" ]; then
        summary="$(printf '%s\n' "$LAST_ASSISTANT" | awk '
            NF == 0 { next }
            seen == 0 && ((tolower($0) ~ /reminder/ && tolower($0) ~ /taskcreate/) || tolower($0) ~ /system-reminder/) { next }
            seen == 0 && (tolower($0) ~ /^(sure|okay|ok|alright|got it|understood|perfect|great|done)[[:punct:][:space:]]*$/) { next }
            { seen = 1; print }
        ' | head -n 4)"
    fi
    if [ -z "$summary" ]; then
        # A thinking/tool-only session (no final prose turn) still did real work —
        # surface the command activity instead of claiming the transcript was
        # unavailable (HIMMEL-576). Only fall back to "unavailable" when there is
        # genuinely nothing.
        if [ -n "${KEPT_COMMANDS:-}" ]; then
            local _ncmd
            _ncmd="$(printf '%s\n' "$KEPT_COMMANDS" | awk 'NF' | wc -l | tr -d ' ')"
            summary="_Tool-only session: ${_ncmd} command(s) run, no prose turn captured._"
        else
            summary="_Transcript unavailable; auto-summary not generated._ (speculation)"
        fi
    fi

    local preamble
    preamble="Auto-captured Claude Code session in repo [[${REPO_NAME}]] on branch \`${BRANCH}\`. Filed by the end-session-wiki hook (epic #7 / task #26)."

    # Files section
    local files_section=""
    if [ "${FILES_COUNT:-0}" -eq 0 ]; then
        files_section="_None._"
    else
        local shown
        # shellcheck disable=SC2016  # backtick chars in sed replacement are literal markdown
        shown="$(printf '%s\n' "${FILES_RAW:-}" | head -n 50 | sed 's/^/- `/; s/$/`/')"
        files_section="$shown"
        if [ "${FILES_COUNT:-0}" -gt 50 ]; then
            local remain
            remain=$(( FILES_COUNT - 50 ))
            files_section="${files_section}
- _+${remain} more (use git log to inspect)_"
        fi
    fi

    # Commands fenced block
    local cmds_section
    cmds_section='```bash'
    if [ -n "${KEPT_COMMANDS:-}" ]; then
        cmds_section="${cmds_section}
${KEPT_COMMANDS}"
    fi
    cmds_section="${cmds_section}
\`\`\`"

    # Raw conversation callout
    local raw_section=""
    if [ "${TRANSCRIPT_READABLE:-0}" -eq 1 ] && [ -n "${LAST_ASSISTANT:-}" ]; then
        local raw_body
        raw_body="$(printf '%s\n' "$LAST_ASSISTANT" | sed 's/^/> /')"
        raw_section="> [!note]- Raw conversation
${raw_body}"
    else
        raw_section="> [!note]- Raw conversation
> _Transcript unavailable._"
    fi

    cat <<EOF
---
date: ${NOW_ISO}
type: session
repo: ${REPO_NAME}
branch: ${BRANCH}
worktree: ${WORKTREE_ABS}
duration_minutes: ${DURATION_MINUTES}
files_touched: ${FILES_COUNT}
tags:
  - session
  - autocapture
ai-first: true
session_id: ${SESSION_ID}
source: ${SOURCE}
crystallized: ${CRYSTALLIZED:-false}
crystallized_at: ${CRYSTALLIZED_AT:-}
---

${preamble}

## Summary

${summary}

## Decisions

_None._

## Files Touched

${files_section}

## Commands

${cmds_section}

## Follow-ups

_None._

## Raw Conversation

${raw_section}
EOF
}
