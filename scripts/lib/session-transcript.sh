#!/usr/bin/env bash
# session-transcript.sh — JSONL transcript parsing for end-session-wiki.
#
# Source this file, then call the functions below.  All functions set
# named globals directly (bash 3.2-safe; no mapfile / declare -A).
# shellcheck disable=SC2034  # globals (FIRST_TS, LAST_TS, LAST_ASSISTANT, etc.) are read by callers
#
# Functions:
#   parse_session_transcript <transcript_path>
#     Sets: FIRST_TS, LAST_TS, LAST_ASSISTANT, COMMANDS, TRANSCRIPT_READABLE,
#           HAS_CONTENT (1 if any salvageable signal, 0 for a content-free husk)
#
#   compute_duration <first_ts> <now_epoch>
#     Sets: DURATION_SECONDS, DURATION_MINUTES
#
#   filter_commands <commands_text>
#     Sets: KEPT_COMMANDS

# parse_session_transcript <transcript_path>
# Reads the JSONL transcript file and populates transcript-derived globals.
# On success: FIRST_TS (may be empty), LAST_TS (may be empty), LAST_ASSISTANT, COMMANDS set.
# TRANSCRIPT_READABLE is set to 1 on success, 0 if file unreadable.
parse_session_transcript() {
    local transcript_path="$1"

    FIRST_TS=""
    LAST_TS=""
    LAST_ASSISTANT=""
    COMMANDS=""
    TRANSCRIPT_READABLE=1
    HAS_CONTENT=0

    if [ -n "$transcript_path" ] && [ -r "$transcript_path" ]; then
        # First timestamp (earliest line with .timestamp)
        FIRST_TS="$(jq -r 'select(.timestamp) | .timestamp' "$transcript_path" 2>/dev/null | head -n1)"
        # Last timestamp (latest line with .timestamp) — used by backfill for duration
        LAST_TS="$(jq -r 'select(.timestamp) | .timestamp' "$transcript_path" 2>/dev/null | tail -n1)"
        # Last assistant turn text (concat text blocks). Supports both top-level
        # role/content and nested message.role/message.content shapes.
        LAST_ASSISTANT="$(
            jq -r '
                . as $line
                | (
                    (if .role then {role:.role, content:.content} else null end) //
                    (if .message and .message.role then {role:.message.role, content:.message.content} else null end)
                  )
                | select(. != null and .role == "assistant")
                | (if (.content|type) == "string"
                   then .content
                   else (.content // [] | map(select(.type=="text") | .text) | join("\n"))
                  end)
                | select(length > 0)
            ' "$transcript_path" 2>/dev/null | tail -n 200
        )"
        # Bash/PowerShell tool commands (in chronological order)
        COMMANDS="$(
            jq -r '
                . as $line
                | (
                    (if .role then .content else null end) //
                    (if .message then .message.content else null end)
                  )
                | select(. != null and (type == "array"))
                | .[]?
                | select(.type == "tool_use" and (.name == "Bash" or .name == "PowerShell"))
                | .input.command // empty
            ' "$transcript_path" 2>/dev/null
        )"
        # HAS_CONTENT: 1 if the transcript carries ANY salvageable signal — a
        # non-empty string-content assistant turn, an assistant text/thinking
        # block, or ANY tool_use block (any tool, not just Bash). Used by the
        # husk-skip gate (HIMMEL-576) so content-free sessions never write a
        # "Transcript unavailable" husk note. A thinking/tool-only session (no
        # final text turn → empty LAST_ASSISTANT) is therefore NOT a husk.
        if [ -n "$COMMANDS" ]; then
            HAS_CONTENT=1
        else
            local _sig
            _sig="$(
                jq -r '
                    . as $line
                    | (
                        (if .role then {role:.role, content:.content} else null end) //
                        (if .message and .message.role then {role:.message.role, content:.message.content} else null end)
                      )
                    | select(. != null and .role == "assistant")
                    | (if (.content|type) == "string"
                       then (if (.content|length) > 0 then "x" else empty end)
                       else (.content // [] | map(select(.type=="text" or .type=="thinking" or .type=="tool_use")) | if length > 0 then "x" else empty end)
                      end)
                ' "$transcript_path" 2>/dev/null | head -n1
            )"
            [ -n "$_sig" ] && HAS_CONTENT=1
        fi
    else
        TRANSCRIPT_READABLE=0
    fi
}

# compute_duration <first_ts> <now_epoch>
# Computes the session duration from a transcript timestamp and a Unix epoch.
# Sets: DURATION_SECONDS (int), DURATION_MINUTES (int, rounded to nearest minute).
# Falls back to 0/0 if the timestamp can't be parsed.
compute_duration() {
    local first_ts="$1" now_epoch="$2"

    DURATION_SECONDS=0
    DURATION_MINUTES=0

    if [ -n "$first_ts" ] && [ -n "$now_epoch" ]; then
        # GNU date understands ISO 8601 with Z; fall back to 0 on failure
        local start_epoch
        start_epoch="$(date -u -d "$first_ts" +%s 2>/dev/null || echo "")"
        if [ -n "$start_epoch" ] && [ "$start_epoch" -gt 0 ]; then
            local delta diff
            delta=$(( now_epoch - start_epoch ))
            [ "$delta" -lt 0 ] && delta=0
            DURATION_SECONDS="$delta"
            diff=$(( (delta + 30) / 60 ))
            [ "$diff" -lt 0 ] && diff=0
            DURATION_MINUTES="$diff"
        fi
    fi
}

# filter_commands <commands_text>
# Filters trivial commands (ls, cd, pwd, echo) and caps at the last 20.
# Sets: KEPT_COMMANDS
filter_commands() {
    local commands_text="$1"

    KEPT_COMMANDS=""
    if [ -n "$commands_text" ]; then
        KEPT_COMMANDS="$(printf '%s\n' "$commands_text" \
            | grep -Ev '^(ls|cd|pwd|echo)( |$)' \
            | tail -n 20 || true)"
    fi
}
