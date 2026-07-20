#!/usr/bin/env bash
# PreToolUse guard for the Claude Code auto-memory store (HIMMEL-570 / HIMMEL-1088).
#
# The always-loaded MEMORY.md index is O(themes), not O(facts): it carries one
# <=200-char ROUTING line per theme, and the facts live in the theme TOPIC FILES
# it names (natively lazy-loaded by the harness). This guard enforces ONLY the
# mechanically-decidable FORM rules on that index — line length, a hard pointer-
# line ceiling, and net growth — and logs a line-count tripwire + a deny record.
# Everything semantic (is this status-only? does a theme already cover it?) is
# NOT decidable here and is left to the model + the memory-compound skill.
#
# Design authority: spec HIMMEL-1076-memory-strategy.md **Revision 2** (D4 AMEND)
# and the 2026-07-17 Phase-0 spike (INDEX_APPEND_TOOL=Edit -> Write|Edit matcher +
# .new_string deny-log fallback are load-bearing, not optional).
#
# Scope: only files under */.claude/projects/*/memory/*.
#   MEMORY.md  -> line rule + ~60-line ceiling + growth cap + tripwire log;
#                 Edit/MultiEdit/NotebookEdit denied (force whole-file Write —
#                 their payloads don't reveal the resulting line count/length).
#   topic file -> tier-2 landing spot; UNRESTRICTED (no body cap, Edit allowed).
#   *.bak      -> exempt (compound writes a ~25KB backup by design).
#
# Adopter story is UNCONDITIONAL: no vault/qmd predicate. A machine with no
# substrate still gets index form-gating (the rules are pure form) and still
# captures freely into topic files.
#
# Exit semantics: 0 = allow (optional JSON advisory on stdout); 2 = deny, with a
# retry contract on stderr (shown to the model). deny != ask — `ask` hangs
# unattended sessions.
set -uo pipefail

LINE_MAX="${MEMORY_LINE_MAX:-200}"
LINE_CEIL="${MEMORY_LINE_CEIL:-60}"
GROWTH_MAX="${MEMORY_GROWTH_MAX:-400}"

payload="$(cat)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // ""')"
fp="$(printf '%s' "$payload"   | jq -r '.tool_input.file_path // ""')"
# `.content` is Write; `.new_string` is Edit/MultiEdit. WITHOUT the fallback an
# Edit deny logs an empty hash+excerpt, and the audit's orphaned-deny loop skips
# empty excerpts. The spike measured INDEX_APPEND_TOOL=Edit for the index append,
# so this is the arm that actually fires on routine capture — not an edge case.
content="$(printf '%s' "$payload" | jq -r '.tool_input.content // .tool_input.new_string // ""')"

# 1. Bypass FIRST — before any deny branch. Restart-only by nature (an env var in
#    the launching shell; a per-call prefix does not reach a running session).
[ "${MEMORY_CAPTURE_OK:-0}" = "1" ] && exit 0

# 2. Normalize the path BEFORE matching. Claude Code payloads on Windows carry
#    `C:\Users\...\.claude\projects\...` backslash paths, which the POSIX glob
#    below never matches -> the hook silently no-ops across its ENTIRE scope
#    (fail-open, no gate, no tripwire log). Verified live 2026-07-16.
#    `tr` (not `${fp//\\\\//}`): the parameter-expansion form proved a no-op in
#    this hook's non-interactive bash — same armored approach as
#    block-edit-on-main.sh's canon(). Octal \134 = backslash (avoids shellcheck
#    SC1003's false single-quote-escape warning on a literal '\\').
fp="$(printf '%s' "$fp" | tr '\134' '/')"

# 3. Scope: only the auto-memory store.
case "$fp" in
    */.claude/projects/*/memory/*) ;;
    *) exit 0 ;;
esac

# 4. *.bak exempt (compound writes a ~25KB backup by design).
case "$fp" in *.bak) exit 0 ;; esac

MEMDIR="$(dirname "$fp")"
LOG="${MEMORY_CAPTURE_LOG:-$MEMDIR/.capture-log.jsonl}"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
lane="$(hostname 2>/dev/null || echo unknown)"

log_rec() { # $1=event $2=rule $3=lines_delta
    hash="$(printf '%s' "$content" | sha256sum 2>/dev/null | cut -d' ' -f1)"
    excerpt="$(printf '%s' "$content" | tr '\n' ' ' | cut -c1-120)"
    jq -nc --arg ts "$now" --arg e "$1" --arg r "$2" --arg h "${hash:-}" \
           --arg x "$excerpt" --arg t "$MEMDIR" --arg l "$lane" \
           --argjson d "${3:-0}" \
      '{ts:$ts,event:$e,rule:$r,hash:$h,excerpt:$x,target:$t,lines_delta:$d,lane:$l}' \
      >> "$LOG" 2>/dev/null || true
}

deny() { # $1=rule $2=message
    log_rec deny "$1" 0
    printf 'MEMORY CAPTURE DENIED (%s)\n\n%s\n\n' "$1" "$2" >&2
    printf 'Remedy, in this session: append the durable body to the theme topic\n' >&2
    printf 'file named by a routing line in this index (create a new theme note if\n' >&2
    printf 'none fits), then retry this write with a <=%s-char routing line:\n' "$LINE_MAX" >&2
    printf '"<keyword hook> -> luna [[note]]".\n' >&2
    exit 2
}

base="$(basename "$fp")"

if [ "$base" = "MEMORY.md" ]; then
    # Edit/MultiEdit/NotebookEdit payloads don't reveal the resulting line count
    # or length -> force a whole-file Write we CAN inspect. (Topic files, below,
    # keep Edit — there is nothing to inspect there under the tier-2 design.)
    case "$tool" in
        Edit|MultiEdit|NotebookEdit)
            deny "undecidable-payload" "$tool payloads do not reveal MEMORY.md's resulting line length or count. Write the whole file with Write instead." ;;
    esac

    # awk, NOT `grep -c ... || echo 0`: grep -c PRINTS 0 AND EXITS 1 on zero
    # matches, so `|| echo 0` appends a second 0 -> "0\n0" -> the arithmetic
    # dies -> the hook exits 1 -> PreToolUse treats exit 1 as a NON-BLOCKING
    # error -> the write PROCEEDS ungated and unlogged (fail-open on exactly the
    # writes this hook exists to gate). awk has no exit-status trap.
    old_lines=0; [ -f "$fp" ] && old_lines="$(awk '/^- /{n++} END{print n+0}' "$fp")"
    new_lines="$(printf '%s\n' "$content" | awk '/^- /{n++} END{print n+0}')"
    lines_delta="$((new_lines - old_lines))"

    # a. Any pointer line over the length budget -> deny (whole-file Write; diffing
    #    to find only the NEW line is YAGNI for this small file).
    if printf '%s\n' "$content" | awk -v m="$LINE_MAX" '/^- /{if (length($0)>m) exit 1}'; then :; else
        deny "line-too-long" "A pointer line exceeds ${LINE_MAX} chars. The index routes; it does not store — split the fact into its theme topic file."
    fi

    # b. Hard pointer-line ceiling (Rev2 D4) — the structural bound on n. Judgement
    #    still allocates lines WITHIN the ceiling; O(facts) degeneration hits a wall.
    if [ "$new_lines" -gt "$LINE_CEIL" ]; then
        deny "line-ceiling" "MEMORY.md would carry ${new_lines} pointer lines (ceiling ${LINE_CEIL}). Themes are degenerating into per-fact lines — evict facts to their topic files."
    fi

    # c. Net growth cap. Raises evasion friction; does NOT prevent it (sequential
    #    <=400B writes evade it — claim downgraded accordingly).
    old_b=0; [ -f "$fp" ] && old_b="$(wc -c < "$fp" | tr -d ' ')"
    new_b="$(printf '%s' "$content" | wc -c | tr -d ' ')"
    if [ "$((new_b - old_b))" -gt "$GROWTH_MAX" ]; then
        deny "growth-cap" "This write grows MEMORY.md by $((new_b - old_b))B (cap ${GROWTH_MAX}B)."
    fi

    # Tripwire logged AFTER the gates, so a DENIED write never records a delta that
    # did not land. (Logging first meant a model retrying a denied append 3x logged
    # phantom lines -> false TRIPWIRE findings in the audit.)
    log_rec write "line-delta" "$lines_delta"
fi
# Topic files: tier-2 landing spot under the theme-file design — unrestricted
# (no body cap, Edit allowed). Nothing to gate. Fall through to allow.

# 5. Allow. Optional advisory — ONLY meaningful because the spike verified
#    additionalContext reaches the model on this client, and it arrives
#    AFTER the write ("you just captured X; note Y for next time"), never as a
#    pre-action steer. Default OFF (opt-in via the settings `env` block or the
#    launching shell) to keep routine captures quiet.
if [ "${MEMORY_GUARD_ADVISORY:-0}" = "1" ]; then
    jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",additionalContext:"Memory capture contract: the durable body belongs in the theme topic file the index routes to (append there); the MEMORY.md line stays a <=200-char route. Status-only facts (PR numbers, dates, \"merged\") do not belong in memory at all."}}'
fi
exit 0
