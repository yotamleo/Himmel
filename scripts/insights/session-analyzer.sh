#!/usr/bin/env bash
# session-analyzer.sh — Full-corpus Claude session analyzer for himmel.
#
# Usage: bash scripts/insights/session-analyzer.sh [OPTIONS]
#
# Options:
#   --projects-dir <dir>   Override projects root (default: ~/.claude/projects)
#   --out <path>           Write report to file instead of stdout
#   --since <YYYY-MM-DD>   Only include sessions on or after this date
#   --help|-h              Show this help and exit
#
# Session inclusion: NON-subagent transcripts only (paths with /subagents/ excluded).
# Output: local markdown report — no network calls.
#
# bash 3.2-safe; shellcheck-clean; cross-platform (Git Bash / macOS / Linux).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# Source session-transcript library
_ST_LIB="$LIB_DIR/session-transcript.sh"
# shellcheck source=/dev/null
. "$_ST_LIB" || { printf 'session-analyzer: cannot source %s\n' "$_ST_LIB" >&2; exit 1; }

# Required external command (jq drives all transcript parsing).
command -v jq >/dev/null 2>&1 || { printf 'session-analyzer: jq not found (required)\n' >&2; exit 1; }

# ---------------------------------------------------------------------------
# Cross-platform HOME resolution (mirrors backfill-sessions.sh)
# ---------------------------------------------------------------------------
if [ -n "${HOME:-}" ]; then
    _HOME="$HOME"
elif [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
    _HOME="$(cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE")"
else
    _HOME="${USERPROFILE:-/tmp}"
fi

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PROJECTS_DIR="$_HOME/.claude/projects"
OUT_PATH=""
SINCE_DATE=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --projects-dir)
            [ $# -ge 2 ] || { printf 'session-analyzer: --projects-dir requires a value\n' >&2; exit 1; }
            PROJECTS_DIR="$2"; shift 2 ;;
        --out)
            [ $# -ge 2 ] || { printf 'session-analyzer: --out requires a value\n' >&2; exit 1; }
            OUT_PATH="$2"; shift 2 ;;
        --since)
            [ $# -ge 2 ] || { printf 'session-analyzer: --since requires a value\n' >&2; exit 1; }
            SINCE_DATE="$2"; shift 2 ;;
        --help|-h)
            grep '^#' "$0" | grep -v '^#!/' | sed 's/^# *//'
            exit 0
            ;;
        *)
            printf 'session-analyzer: unknown argument: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Temp files
# ---------------------------------------------------------------------------
# Fallback names include $$ AND $RANDOM so they are not predictable on a shared
# /tmp when mktemp is unavailable (mktemp is the primary path on all real systems).
_rnd="${RANDOM:-0}$$"
TMP_JSONL_ALL="$(mktemp 2>/dev/null)"  || TMP_JSONL_ALL="/tmp/sa-all-$_rnd"
TMP_JSONL_SESS="$(mktemp 2>/dev/null)" || TMP_JSONL_SESS="/tmp/sa-sess-$_rnd"
TMP_MONTHS="$(mktemp 2>/dev/null)"     || TMP_MONTHS="/tmp/sa-mon-$_rnd"
TMP_PROJS="$(mktemp 2>/dev/null)"      || TMP_PROJS="/tmp/sa-prj-$_rnd"
TMP_SESSIONS="$(mktemp 2>/dev/null)"   || TMP_SESSIONS="/tmp/sa-ses-$_rnd"
TMP_JQ_ROWS="$(mktemp 2>/dev/null)"    || TMP_JQ_ROWS="/tmp/sa-jqr-$_rnd"
TMP_REPORT="$(mktemp 2>/dev/null)"     || TMP_REPORT="/tmp/sa-rpt-$_rnd"
TMP_FRICTION_DIR="$(mktemp -d 2>/dev/null)" || { TMP_FRICTION_DIR="/tmp/sa-fric-$_rnd"; mkdir -p "$TMP_FRICTION_DIR"; }

_cleanup() {
    rm -f "$TMP_JSONL_ALL" "$TMP_JSONL_SESS" "$TMP_MONTHS" "$TMP_PROJS" \
          "$TMP_SESSIONS" "$TMP_JQ_ROWS" "$TMP_REPORT" 2>/dev/null || true
    rm -rf "$TMP_FRICTION_DIR" 2>/dev/null || true
}
trap _cleanup EXIT

# ---------------------------------------------------------------------------
# Step 1: Enumerate ALL JSONL files (2-level scan: top-level + subagent dirs)
#
# Claude Code project dirs contain:
#   projects/<proj>/*.jsonl                    — main session transcripts
#   projects/<proj>/<uuid>/subagents/*.jsonl   — subagent transcripts (depth 3)
# We collect both for the total count; the session list excludes subagents.
# ---------------------------------------------------------------------------
if [ -d "$PROJECTS_DIR" ]; then
    for _d in "$PROJECTS_DIR"/*/; do
        [ -d "$_d" ] || continue
        # Top-level JSONL files (main sessions + some subagents at depth 2)
        for _f in "$_d"*.jsonl; do
            [ -f "$_f" ] && printf '%s\n' "$_f"
        done
        # Depth-3 JSONL files (subagents nested under UUID dirs)
        for _sd in "$_d"*/subagents/; do
            [ -d "$_sd" ] || continue
            for _f in "$_sd"*.jsonl; do
                [ -f "$_f" ] && printf '%s\n' "$_f"
            done
        done
    done > "$TMP_JSONL_ALL"
fi

TOTAL_JSONL=0
if [ -s "$TMP_JSONL_ALL" ]; then
    TOTAL_JSONL="$(wc -l < "$TMP_JSONL_ALL" | tr -d ' ')"
fi

# ---------------------------------------------------------------------------
# Step 2: Filter to non-subagent sessions only
# ---------------------------------------------------------------------------
while IFS= read -r _f; do
    _norm="$(printf '%s' "$_f" | awk '{gsub(/\\/, "/"); print}')"
    case "$_norm" in
        */subagents/*) continue ;;
    esac
    printf '%s\n' "$_f"
done < "$TMP_JSONL_ALL" > "$TMP_JSONL_SESS"

# ---------------------------------------------------------------------------
# Step 3: Single bulk jq pass over all session files.
#
# Strategy: inject a FILE_SENTINEL line before each file's content, then pipe
# all content through a SINGLE jq invocation.  The sentinel is a valid JSON
# object with a special "_file" key that jq uses to track boundaries.
#
# Output format (one tab-separated line per session):
#   <file_path> TAB <first_ts> TAB <last_ts> TAB <bash> TAB <edit> TAB <write> TAB <read> TAB <agent> TAB <skill>
#
# We build the sentinel-interleaved stream in awk and pipe to jq.
# ---------------------------------------------------------------------------

# Build the awk script that interleaves sentinels and emits records.
# awk reads TMP_JSONL_SESS (list of paths), outputs sentinel+file content.
# Then jq processes the merged stream.

awk '
    # For each path in the session list, print a sentinel then the file content.
    # The sentinel embeds the path inside a JSON string, so backslashes and
    # double-quotes MUST be escaped or jq drops the record (paths with special
    # chars). Escape order: backslash first, then double-quote.
    {
        path = $0
        esc = path
        gsub(/\\/, "\\\\", esc)
        gsub(/"/, "\\\"", esc)
        print "{\"__FILE__\":\"" esc "\"}"
        while ((getline line < path) > 0) {
            print line
        }
        close(path)
    }
' "$TMP_JSONL_SESS" | \
jq -r '
    # Emit a FILE sentinel, then for every other row emit TS: and/or TOOL: lines.
    # A single row can have both .timestamp AND tool_use in .message.content,
    # so we always check both — no if/elif/else chaining.
    if .__FILE__ then
        "FILE:\(.__FILE__)"
    else
        (if .timestamp then "TS:\(.timestamp)" else empty end),
        (
            ((.message.content // .content) // [])
            | if type == "array" then .[] else empty end
            | select(.type == "tool_use")
            | "TOOL:\(.name)"
        )
    end
' 2>/dev/null | \
awk -F'\t' '
    /^FILE:/ {
        if (cur_file != "" && first_ts != "") {
            printf "%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n",
                cur_file, first_ts, last_ts,
                bash, edit, write, read, agent, skill
        }
        cur_file = substr($0, 6)
        first_ts = ""; last_ts = ""
        bash=0; edit=0; write=0; read=0; agent=0; skill=0
        next
    }
    /^TS:/ {
        ts = substr($0, 4)
        if (first_ts == "") first_ts = ts
        last_ts = ts
        next
    }
    /^TOOL:Bash/        { bash++; next }
    /^TOOL:PowerShell/  { bash++; next }
    /^TOOL:Edit/        { edit++; next }
    /^TOOL:Write/       { write++; next }
    /^TOOL:Read/        { read++; next }
    /^TOOL:Agent/       { agent++; next }
    /^TOOL:Skill/       { skill++; next }
    END {
        if (cur_file != "" && first_ts != "") {
            printf "%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n",
                cur_file, first_ts, last_ts,
                bash, edit, write, read, agent, skill
        }
    }
' > "$TMP_JQ_ROWS"

# ---------------------------------------------------------------------------
# Step 4: Process jq rows — count sessions, accumulate metrics
# ---------------------------------------------------------------------------
SESSION_COUNT=0
GLOBAL_MIN_TS=""
GLOBAL_MAX_TS=""
TOOL_BASH=0
TOOL_EDIT=0
TOOL_WRITE=0
TOOL_READ=0
TOOL_AGENT=0
TOOL_SKILL=0

while IFS='	' read -r jl first_ts last_ts cnt_bash cnt_edit cnt_write cnt_read cnt_agent cnt_skill; do
    [ -n "$jl" ] || continue
    [ -n "$first_ts" ] || continue

    session_date="$(printf '%s' "$first_ts" | awk -F'T' '{print $1}')"
    session_month="$(printf '%s' "$session_date" | awk -F'-' '{printf "%s-%s", $1, $2}')"

    # --since filter
    if [ -n "$SINCE_DATE" ] && [ "$session_date" \< "$SINCE_DATE" ]; then
        continue
    fi

    SESSION_COUNT=$((SESSION_COUNT + 1))

    if [ -z "$GLOBAL_MIN_TS" ] || [ "$first_ts" \< "$GLOBAL_MIN_TS" ]; then
        GLOBAL_MIN_TS="$first_ts"
    fi
    if [ -z "$GLOBAL_MAX_TS" ] || [ "$last_ts" \> "$GLOBAL_MAX_TS" ]; then
        GLOBAL_MAX_TS="$last_ts"
    fi

    printf '%s\n' "$session_month" >> "$TMP_MONTHS"
    printf '%s\n' "$(basename "$(dirname "$jl")")" >> "$TMP_PROJS"
    printf '%s\n' "$jl" >> "$TMP_SESSIONS"

    TOOL_BASH=$((TOOL_BASH + cnt_bash))
    TOOL_EDIT=$((TOOL_EDIT + cnt_edit))
    TOOL_WRITE=$((TOOL_WRITE + cnt_write))
    TOOL_READ=$((TOOL_READ + cnt_read))
    TOOL_AGENT=$((TOOL_AGENT + cnt_agent))
    TOOL_SKILL=$((TOOL_SKILL + cnt_skill))

done < "$TMP_JQ_ROWS"

# ---------------------------------------------------------------------------
# Step 5: Friction detection — ONE grep per pattern across included sessions
# ---------------------------------------------------------------------------

# Friction patterns: "label|ERE_pattern"  (label has no spaces or |)
FRICTION_DEFS="block-edit-on-main|block-edit-on-main
block-read-secrets|block-read-secrets
pre-commit-failure|pre-commit.*fail
shellcheck-failure|[Ss]hell[Cc]heck.*(fail|error|Error)
permission-denied|Permission denied
platforms-tested-gate|Platforms tested
security-reviewed-gate|Security reviewed
classifier-prompt|classifier.*veto|blocked by classifier"

if [ -s "$TMP_SESSIONS" ]; then
    # Read all included session paths into a variable (needed for xargs)
    # Use while-loop + grep -l for each pattern (grep reads the file list via stdin)
    printf '%s' "$FRICTION_DEFS" | while IFS='|' read -r label pattern; do
        [ -z "$label" ] && continue
        frict_file="$TMP_FRICTION_DIR/$label"
        # grep -l prints filenames with at least one match
        # Pipe file list to xargs grep -l (portable, avoids ARG_MAX)
        # Null-terminate for xargs -0. Use octal \000, not \0 — BSD/macOS tr
        # treats \0 literally; \000 is the portable POSIX null escape.
        tr '\n' '\000' < "$TMP_SESSIONS" | xargs -0 grep -lE "$pattern" 2>/dev/null \
            >> "$frict_file" || true
    done
fi

# ---------------------------------------------------------------------------
# Step 6: Render report
# ---------------------------------------------------------------------------
# Prefer UTC; fall back to local time WITHOUT a false 'Z' suffix if -u is unsupported.
GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
[ -n "$GENERATED_AT" ] || GENERATED_AT="$(date '+%Y-%m-%dT%H:%M:%S')"

{
    printf '# Session Analyzer Report\n\n'
    printf 'Generated: %s\n\n' "$GENERATED_AT"

    printf '## Summary\n\n'
    printf 'Sessions analyzed: %d\n' "$SESSION_COUNT"
    printf 'Total JSONL on disk: %d  (sessions + subagents)\n' "$TOTAL_JSONL"
    printf 'Date range: %s → %s\n' \
        "$(printf '%s' "$GLOBAL_MIN_TS" | awk -F'T' '{print $1}')" \
        "$(printf '%s' "$GLOBAL_MAX_TS" | awk -F'T' '{print $1}')"
    if [ -n "$SINCE_DATE" ]; then
        printf 'Filter: --since %s\n' "$SINCE_DATE"
    fi
    printf '\n'

    printf '## Sessions per Month\n\n'
    printf '| Month   | Sessions |\n'
    printf '|---------|----------|\n'
    if [ -s "$TMP_MONTHS" ]; then
        sort "$TMP_MONTHS" | uniq -c | sort -k2 | awk '{printf "| %s | %d |\n", $2, $1}'
    else
        printf '| (none)  | 0        |\n'
    fi
    printf '\n'

    printf '## Top Projects by Session Count\n\n'
    printf '| Project | Sessions |\n'
    printf '|---------|----------|\n'
    if [ -s "$TMP_PROJS" ]; then
        sort "$TMP_PROJS" | uniq -c | sort -rn | head -20 | awk '{
            slug = $2
            if (length(slug) > 60) slug = substr(slug, 1, 57) "..."
            printf "| %s | %d |\n", slug, $1
        }'
    else
        printf '| (none)  | 0        |\n'
    fi
    printf '\n'

    printf '## Tool Usage Aggregate\n\n'
    printf '| Tool              | Occurrences |\n'
    printf '|-------------------|-------------|\n'
    printf '| Bash/PowerShell   | %d |\n' "$TOOL_BASH"
    printf '| Edit              | %d |\n' "$TOOL_EDIT"
    printf '| Write             | %d |\n' "$TOOL_WRITE"
    printf '| Read              | %d |\n' "$TOOL_READ"
    printf '| Agent             | %d |\n' "$TOOL_AGENT"
    printf '| Skill             | %d |\n' "$TOOL_SKILL"
    printf '\n'

    printf '## Friction Signals\n\n'
    printf '_Guardrail / gate markers detected across session transcripts._\n\n'
    printf '| Signal | Sessions Hit |\n'
    printf '|--------|-------------|\n'
    printf '%s' "$FRICTION_DEFS" | while IFS='|' read -r label pattern; do
        [ -z "$label" ] && continue
        frict_file="$TMP_FRICTION_DIR/$label"
        count=0
        [ -f "$frict_file" ] && count="$(wc -l < "$frict_file" | tr -d ' ')"
        printf '| %s | %d |\n' "$label" "$count"
    done
    printf '\n'

    printf '### Top Sessions per Friction Signal\n\n'
    printf '%s' "$FRICTION_DEFS" | while IFS='|' read -r label pattern; do
        [ -z "$label" ] && continue
        frict_file="$TMP_FRICTION_DIR/$label"
        [ -f "$frict_file" ] || continue
        count="$(wc -l < "$frict_file" | tr -d ' ')"
        case "$count" in 0|"") continue ;; esac
        printf '**%s** (%d session(s)):\n' "$label" "$count"
        head -3 "$frict_file" | while IFS= read -r sess_path; do
            # shellcheck disable=SC2016  # backtick in format string is markdown, not shell
            printf '  - `%s`\n' "$(basename "$sess_path")"
        done
        printf '\n'
    done

} > "$TMP_REPORT"

# ---------------------------------------------------------------------------
# Step 7: Output
# ---------------------------------------------------------------------------
if [ -n "$OUT_PATH" ]; then
    cp "$TMP_REPORT" "$OUT_PATH"
else
    cat "$TMP_REPORT"
fi
