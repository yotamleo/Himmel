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
#   LAST_ASSISTANT      — last assistant turn text (may be empty)
#   TRANSCRIPT_READABLE — 1 if transcript was readable, 0 otherwise
#   KEPT_COMMANDS       — filtered command list (may be empty)

render_session_note() {
    # Summary: first 4 non-empty lines of last assistant turn
    local summary=""
    if [ -n "${LAST_ASSISTANT:-}" ]; then
        summary="$(printf '%s\n' "$LAST_ASSISTANT" | awk 'NF' | head -n 4)"
    fi
    if [ -z "$summary" ]; then
        summary="_Transcript unavailable; auto-summary not generated._ (speculation)"
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
