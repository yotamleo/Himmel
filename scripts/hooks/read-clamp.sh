#!/usr/bin/env bash
# read-clamp.sh — PreToolUse hook (matchers "Read|Grep" and "Bash"): denies a
# whole-file Read/cat/sed/head of a file over HIMMEL_READ_CLAMP_LINES lines,
# and denies a repeated Read of the exact same (path, offset, limit) triple,
# inside a console-spawned leg-impl session (HIMMEL-2993).
#
# WHY: measured over 12 merged-PR leg sessions, repeated Reads of the same
# file cost ~4.5% of a PR's token bill and whole-file reads ~2.2% (6.7%
# together, the #2/#3 levers after HIMMEL-2990). The instructional layer
# (preface read-range sentence, #692) already exists; this is the structural
# step (root CLAUDE.md "second drift -> hook").
#
# Scope: HIMMEL_CONSOLE_LEG=1 only (headed-arm-leg.sh's launcher export) --
# never gates a console or an interactive session.
#
# Platform guard: bash-only, no .ps1 twin -- leg-impl sessions run under the
# .claude/settings.json Bash launcher (Linux/macOS/Git-Bash), never PowerShell.
#
# Workflow nudge, not a security fence (scripts/hooks/CLAUDE.md "Fail-open vs
# fail-closed"): this hook saves tokens, it does not protect anything, so it
# fails OPEN on anything it cannot parse or record -- missing jq, malformed
# stdin, an unrecognised Bash shape, or a runtime dir it cannot create.
#
# State: one line per allowed read, appended to
#   ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/himmel-read-clamp/<session_id>/reads.tsv
# as "<path>\t<offset>\t<limit>\t<stamp>" (mirrors the
# <XDG_RUNTIME_DIR>/himmel-queue-lock/ convention). A missing/uncreatable
# runtime dir allows the call through with no state written -- this hook
# never fails closed on its own infrastructure.
#
# Bypass: set HIMMEL_READ_CLAMP_OK=1 in the shell that launched the leg to
# allow one session past the clamp (e.g. re-reading a file after an external
# edit invalidated the recorded range). Logged to stderr each time it fires.
#
# Hook I/O: JSON on stdin. exit 0 = allow, exit 2 = deny (stderr message,
# same convention as block-read-secrets.sh / block-leg-askuserquestion.sh).
set -uo pipefail

[ "${HIMMEL_CONSOLE_LEG:-0}" = "1" ] || exit 0

if [ "${HIMMEL_READ_CLAMP_OK:-0}" = "1" ]; then
    echo "read-clamp: HIMMEL_READ_CLAMP_OK=1 -- bypassing the read clamp for this call" >&2
    exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat) || exit 0
[ -n "$input" ] || exit 0

LIMIT_LINES="${HIMMEL_READ_CLAMP_LINES:-400}"

# SOH (not tab): bash's `read` treats tab as an IFS-whitespace class char and
# COLLAPSES consecutive tab delimiters, silently shifting empty offset/limit
# fields into the next column. block-read-secrets.sh hits the same hazard and
# uses the same fix.
SOH=$'\001'
row=$(jq -r --arg sep "$SOH" '
    def chk: if contains($sep) then error("delimiter-collision") else . end;
    ((.tool_name // "")|tostring|chk) + $sep +
    ((.tool_input.file_path // "")|tostring|chk) + $sep +
    ((.tool_input.offset // "")|tostring|chk) + $sep +
    ((.tool_input.limit // "")|tostring|chk) + $sep +
    ((.tool_input.command // "")|tostring|chk) + $sep +
    ((.session_id // "")|tostring|chk)
' <<<"$input" 2>/dev/null) || exit 0
[ -n "$row" ] || exit 0

# Split by parameter expansion, NOT `IFS="$SOH" read`: bash 3.2 (macOS
# /bin/bash) never splits on \001 -- CTLESC is its internal quote byte -- so
# `read` returned the whole row in $tool and every gate below silently allowed
# (HIMMEL-3177). block-read-secrets.sh splits the same way.
tool="${row%%"$SOH"*}"; row="${row#*"$SOH"}"
fp="${row%%"$SOH"*}"; row="${row#*"$SOH"}"
offset="${row%%"$SOH"*}"; row="${row#*"$SOH"}"
limit="${row%%"$SOH"*}"; row="${row#*"$SOH"}"
cmd="${row%%"$SOH"*}"; session_id="${row#*"$SOH"}"

# file_line_count: prints a file's line count, or nothing (and fails) if the
# file cannot be read -- callers must allow on failure, never deny on a guess.
file_line_count() {
    [ -f "$1" ] || return 1  # regular files only -- wc on a FIFO/device can block indefinitely (HIMMEL-2993 CR)
    wc -l < "$1" 2>/dev/null  # fail-open-ok: an unreadable-but-regular file returns empty/rc!=0 here, and the caller's `|| exit 0` already treats that as allow -- documented fail-open (never deny on a guess)
}

# clamp_deny: the one deny message both the Read whole-file path and the Bash
# shapes share (brief: "deny with the same message").
clamp_deny() {  # $1 = path, $2 = line count
    echo "⛔ read-clamp: $1 has $2 lines (> ${LIMIT_LINES}); read a range instead of the whole file: offset=<n> limit=<m>" >&2
    exit 2
}

# strip_quotes: strips one matching pair of surrounding quotes from a captured
# Bash target -- `cat "/path.txt"` otherwise checks a filename that literally
# includes the quote characters, which never exists and silently bypasses the
# clamp (HIMMEL-2993 CR).
strip_quotes() {
    local t="$1"
    case "$t" in
        \"*\") t="${t#\"}"; t="${t%\"}" ;;
        \'*\') t="${t#\'}"; t="${t%\'}" ;;
    esac
    printf '%s\n' "$t"
}

session_state_dir() {
    [ -n "$session_id" ] || return 1
    local root="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/himmel-read-clamp"
    local dir="$root/$session_id"
    mkdir -p "$dir" 2>/dev/null || return 1
    [ -d "$dir" ] || return 1
    printf '%s\n' "$dir"
}

# already_read STAMP_VAR PATH OFFSET LIMIT STATE_FILE -- sets STAMP_VAR and
# returns 0 if that exact (path, offset, limit) triple is already recorded.
# Parsed field-by-field with `cut` rather than `IFS=$'\t' read` -- read's tab
# splitting collapses consecutive delimiters (same hazard as above), and a
# whole-file record has empty offset/limit columns.
already_read() {
    local _ar_path="$2" _ar_offset="$3" _ar_limit="$4" _ar_state="$5"
    [ -f "$_ar_state" ] || return 1  # fail-open-ok: existing-but-unreadable state file makes the redirect below open nothing, the loop runs zero times, and the caller treats "not found" as allow — the documented fail-open (this hook never denies on its own infrastructure)
    local line p o l s
    while IFS= read -r line; do
        p=$(cut -f1 <<<"$line")
        o=$(cut -f2 <<<"$line")
        l=$(cut -f3 <<<"$line")
        # shellcheck disable=SC2034 # written via the eval indirect-assignment below, not used directly here
        s=$(cut -f4 <<<"$line")
        if [ "$p" = "$_ar_path" ] && [ "$o" = "$_ar_offset" ] && [ "$l" = "$_ar_limit" ]; then
            eval "$1=\"\$s\""
            return 0
        fi
    done < "$_ar_state"
    return 1
}

record_read() {  # $1 = path, $2 = offset, $3 = limit, $4 = state file
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(date '+%H:%M:%S')" >> "$4"
}

case "$tool" in
    Read)
        [ -n "$fp" ] || exit 0
        [ -r "$fp" ] || exit 0  # PreToolUse runs before the Read; a nonexistent or unreadable file may be fixed before a retry -- never record a read that didn't happen (HIMMEL-2993 CR)
        state_dir=$(session_state_dir) || exit 0
        state_file="$state_dir/reads.tsv"

        if already_read stamp "$fp" "$offset" "$limit" "$state_file"; then
            # shellcheck disable=SC2154 # stamp is set via already_read's eval indirect-assignment, not directly here
            echo "⛔ read-clamp: already read (${stamp}); read the range you need or a different range" >&2
            exit 2
        fi

        if [ -z "$offset" ] && [ -z "$limit" ]; then
            lines=$(file_line_count "$fp") || exit 0
            [ -n "$lines" ] || exit 0
            if [ "$lines" -gt "$LIMIT_LINES" ] 2>/dev/null; then
                clamp_deny "$fp" "$lines"
            fi
        fi

        record_read "$fp" "$offset" "$limit" "$state_file"
        ;;

    Bash)
        [ -n "$cmd" ] || exit 0
        trimmed="$(printf '%s' "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

        target=""
        if [[ "$trimmed" =~ ^cat[[:space:]]+([^[:space:]\;\|\&\<\>]+)$ ]]; then
            target="${BASH_REMATCH[1]}"
        elif [[ "$trimmed" =~ ^sed[[:space:]]+-n[[:space:]]+\'?1,\$p\'?[[:space:]]+([^[:space:]\;\|\&\<\>]+)$ ]]; then
            target="${BASH_REMATCH[1]}"
        elif [[ "$trimmed" =~ ^head[[:space:]]+-n[[:space:]]+([0-9]+)[[:space:]]+([^[:space:]\;\|\&\<\>]+)$ ]]; then
            n="${BASH_REMATCH[1]}"
            if [ "$n" -gt "$LIMIT_LINES" ] 2>/dev/null; then
                target="${BASH_REMATCH[2]}"
            fi
        fi

        [ -n "$target" ] || exit 0
        target=$(strip_quotes "$target")
        [ -n "$target" ] || exit 0
        lines=$(file_line_count "$target") || exit 0
        [ -n "$lines" ] || exit 0
        if [ "$lines" -gt "$LIMIT_LINES" ] 2>/dev/null; then
            clamp_deny "$target" "$lines"
        fi
        ;;

    *)
        exit 0
        ;;
esac

exit 0
