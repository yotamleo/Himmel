#!/usr/bin/env bash
# telemetry.sh — 0-cost live skill-usage telemetry seam (HIMMEL-236).
#
# WHY: the tool-adoption rubric's measure-BEFORE protocol (rubric §4)
# cannot baseline skills/tools already in the default path (luna-ingest,
# handover-arm-resume, jira CLI, the bridge) — there is no "without"
# workday to capture. The accepted protocol for in-use items is
# measure-DURING: record outcome-per-session signals as a side-effect of
# real work, analyse later. This lib is that seam.
#
# 0-cost contract (the point of HIMMEL-236 — preserve it):
#   - NO stdout output, ever. The record goes to disk, never into model
#     context. (Diagnostics would cost tokens in hook/skill call sites.)
#   - NO network, NO LLM invocation, no expensive processes — only
#     date/git/mkdir/basename (+ their capturing subshells).
#   - FAIL-OPEN: telemetry_emit always returns 0. A broken telemetry
#     seam must never break the instrumented skill (callers run under
#     `set -e`). This inverts the scripts/hooks fail-closed convention
#     deliberately — same rationale as the auto-arm-on-cap watchdog.
#
# Usage (source, then emit — typically once per session per skill):
#   . "$SCRIPT_DIR/../lib/telemetry.sh"
#   telemetry_emit <skill> <event> [key=value ...]
#   e.g. telemetry_emit handover-arm-resume armed time=09:30 force=0
#
# Record format — one JSONL line per emit, appended to
#   $SKILL_TELEMETRY_DIR/skill-usage.jsonl   (default ~/.claude/telemetry)
#   {"v":1,"ts":"<UTC ISO8601>","session_id":"<id|->","repo":"<name|->",
#    "skill":"<skill>","event":"<event>","<key>":"<value>",...}
# Full format spec + analysis guidance: docs/tool-adoption/telemetry.md.
#
# Env knobs:
#   SKILL_TELEMETRY_DISABLE=<any non-empty value>
#                               kill switch (set in the launching shell);
#                               1/true/yes/anything non-empty all disable
#   SKILL_TELEMETRY_DIR         sink dir override (default ~/.claude/telemetry)
#   CLAUDE_SESSION_ID           recorded when set (hooks/wrappers may export
#                               it); "-" otherwise
#
# bash 3.2-compatible (macOS). No associative arrays, no mapfile.

# Escape a value for embedding inside a JSON string: backslash, double
# quote, and the full C0 control range 0x01-0x1F — newline/CR/tab → space
# (cheap and lossless enough for telemetry), every OTHER control char is
# stripped (verbatim ESC/VT/backspace/… would make the line invalid JSON
# and silently poison the shared sink). 0x00 cannot occur in a bash var.
# Pure bash 3.2 ($'\xNN' + ${var//}), no processes spawned.
_telemetry_json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/ }
    s=${s//$'\r'/ }
    s=${s//$'\t'/ }
    local ctrl=$'\x01\x02\x03\x04\x05\x06\x07\x08\x0b\x0c\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f'
    local i c
    for ((i = 0; i < ${#ctrl}; i++)); do
        c=${ctrl:i:1}
        s=${s//$c/}
    done
    printf '%s' "$s"
}

# Resolve the sink directory (no mkdir — emit does that lazily).
telemetry_root() {
    printf '%s' "${SKILL_TELEMETRY_DIR:-$HOME/.claude/telemetry}"
}

# telemetry_emit <skill> <event> [key=value ...]
# Appends ONE JSONL record. Always returns 0; never writes to stdout.
telemetry_emit() {
    [ -n "${SKILL_TELEMETRY_DISABLE:-}" ] && return 0
    local skill="${1:-}" event="${2:-}"
    # Nothing useful to record without both — quiet no-op (fail-open).
    [ -n "$skill" ] && [ -n "$event" ] || return 0
    shift 2 || return 0

    local root ts session repo line kv key val
    root=$(telemetry_root)
    mkdir -p "$root" 2>/dev/null || return 0

    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || ts="-"
    session="${CLAUDE_SESSION_ID:--}"
    repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)
    [ -n "$repo" ] || repo="-"

    line=$(printf '{"v":1,"ts":"%s","session_id":"%s","repo":"%s","skill":"%s","event":"%s"' \
        "$(_telemetry_json_escape "$ts")" \
        "$(_telemetry_json_escape "$session")" \
        "$(_telemetry_json_escape "$repo")" \
        "$(_telemetry_json_escape "$skill")" \
        "$(_telemetry_json_escape "$event")")
    for kv in "$@"; do
        case "$kv" in
            *=*) ;;
            *) continue ;;  # malformed extra — skip, never fail
        esac
        key="${kv%%=*}"
        val="${kv#*=}"
        [ -n "$key" ] || continue
        # Skip keys that collide with reserved fields to avoid duplicate JSON keys.
        case "$key" in
            v|ts|session_id|repo|skill|event) continue ;;
        esac
        line="$line,\"$(_telemetry_json_escape "$key")\":\"$(_telemetry_json_escape "$val")\""
    done
    line="$line}"

    # Single appending write — atomic for lines under PIPE_BUF, which a
    # one-line record always is. Errors are swallowed: fail-open.
    printf '%s\n' "$line" >> "$root/skill-usage.jsonl" 2>/dev/null || true
    return 0
}
