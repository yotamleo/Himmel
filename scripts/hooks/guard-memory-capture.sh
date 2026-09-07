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
#                 Edit/MultiEdit are simulated against the on-disk file (via
#                 simulate-memory-edit.js) and the RESULT runs the same checks
#                 as Write; NotebookEdit still denied (payload doesn't reveal
#                 the resulting content).
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

# Pin the BYTE locale, then count characters explicitly (see the line rule
# below). The contract counts chars, not bytes (header above, deny text below),
# but this env has no LANG/LC_ALL — Windows Git Bash sets it only in login
# shells — so awk's `length()` byte-counts and a multibyte char (an em-dash is
# 3 bytes) tripped the line-too-long deny ~40 chars early. Verified under
# `env -i`. Asking for a UTF-8 locale instead is a bet on two things that are
# not portable: that the locale EXISTS (glibc lists `C.utf8`, macOS/BSD have
# no C.UTF-8 at all) and that awk is UTF-8-aware (mawk and older BSD awk
# byte-count regardless). Pinning C makes both irrelevant — the count below is
# then exact on every platform.
export LC_ALL=C

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
    # NotebookEdit payloads don't reveal the resulting content -> force a
    # whole-file Write we CAN inspect. Edit/MultiEdit ARE decidable: simulate
    # the replacement(s) against the on-disk file and validate the RESULT
    # below via the same $content the Write path checks (one code path, so
    # the rules cannot drift between Write and Edit).
    case "$tool" in
        NotebookEdit)
            deny "undecidable-payload" "$tool payloads do not reveal MEMORY.md's resulting line length or count. Write the whole file with Write instead." ;;
        Edit|MultiEdit)
            hookdir="$(cd "$(dirname "$0")" && pwd)"
            sim="$(printf '%s' "$payload" | node "$hookdir/simulate-memory-edit.js")"
            sim_rc=$?
            case "$sim_rc" in
                # The simulator terminates its output with an EOT sentinel so
                # this `$( )` capture has no trailing newline to strip: without
                # it the growth cap below undercounts an edit that appends
                # them, and the simulated content is not byte-exact.
                0) content="${sim%$'\004'}" ;;
                3) exit 0 ;; # old_string not found; the Edit tool itself errors on this
                # simulation crashed: keep $content at its .new_string fallback (set
                # above) so the deny log still records an excerpt, not an empty one.
                *) deny "undecidable-payload" "$tool payload could not be simulated against MEMORY.md. Write the whole file with Write instead." ;;
            esac
            ;;
    esac

    # awk, NOT `grep -c ... || echo 0`: grep -c PRINTS 0 AND EXITS 1 on zero
    # matches, so `|| echo 0` appends a second 0 -> "0\n0" -> the arithmetic
    # dies -> the hook exits 1 -> PreToolUse treats exit 1 as a NON-BLOCKING
    # error -> the write PROCEEDS ungated and unlogged (fail-open on exactly the
    # writes this hook exists to gate). awk has no exit-status trap.
    old_lines=0; [ -f "$fp" ] && old_lines="$(awk '/^- /{n++} END{print n+0}' "$fp")"  # fail-open-ok: unreadable index reads as an empty awk sum → 0 baseline → the growth/ceiling caps get STRICTER, not looser
    new_lines="$(printf '%s\n' "$content" | awk '/^- /{n++} END{print n+0}')"
    lines_delta="$((new_lines - old_lines))"

    # a. Any ADDED/CHANGED pointer line over the length budget -> deny.
    #    Char count, not byte count: under the pinned C locale `length()` is
    #    bytes, and a UTF-8 char is 1 lead byte + N continuation bytes (\200-\277)
    #    -> dropping the continuation bytes leaves exactly the character count.
    #
    #    Diff-scoped (HIMMEL-2074): checking the WHOLE resulting file re-validates
    #    every PRE-EXISTING line on every write. A legacy line that already
    #    exceeds the cap (grandfathered before this rule existed, or before the
    #    cap was lowered) then denies EVERY future write to the file forever —
    #    including one that only appends an unrelated, fully-compliant line.
    #
    #    MULTISET (bag) difference, not a plain set difference (codex-1, CR
    #    round 1): a naive "is this new line present anywhere in old?" check
    #    (e.g. `grep -Fxvf`) is fooled by DUPLICATION — pasting a second,
    #    genuinely NEW copy of an already-grandfathered over-length line reads
    #    as "already existed" and skips the check entirely, since the text
    #    matches an old line even though this occurrence did not exist before.
    #    The awk pass below counts each OLD line's occurrences, then for each
    #    NEW line consumes one unit of that count if any remains (an
    #    unchanged, pre-existing occurrence) or else emits it as ADDED (a
    #    occurrence beyond what was already there) — the standard per-value
    #    bag-difference algorithm, so duplicate-count changes are caught. A
    #    pre-existing violation with no matching COUNT change is untouched by
    #    THIS write and must not re-trip the gate; a line (or an extra
    #    occurrence of one) this write adds or edits is still checked in
    #    full. `$fp` is read here (not `$content`), same on-disk pre-edit
    #    state `old_lines` above already reads for both the Write and the
    #    simulated Edit/MultiEdit paths (the guard runs BEFORE the write
    #    lands).
    #
    #    CRLF-normalized before comparison (codex-1, CR round 2): an on-disk
    #    MEMORY.md with CRLF endings leaves a trailing \r on every OLD line
    #    (awk splits records on \n only), while an LF-only Write/Edit payload
    #    never carries one — so every untouched line would byte-mismatch its
    #    own old self and read as "added", resurrecting the exact
    #    re-validate-everything bug this fix exists to close. `sub(/\r$/,"")`
    #    runs before the `/^- /` match in both extractions.
    old_pointer_lines=""
    if [ -f "$fp" ]; then
        old_pointer_lines="$(awk '{sub(/\r$/,"")} /^- /' "$fp")" ||
            deny "diff-failed" "Could not extract existing pointer lines from $fp — denying rather than silently skipping the line-length check."
    fi
    # codex-1, CR round on HIMMEL-2074: a failure INSIDE a process-substituted
    # producer (`<(...)`) does not propagate to the consuming awk's exit
    # status — bash never waits on that subshell as part of the pipeline it
    # feeds, so the earlier `||` here only caught the outer awk's own
    # failure, not a producer's. Extract both pointer-line lists as their own
    # checked commands FIRST, then feed them to the diff via plain `printf`
    # process substitution (which cannot itself fail on valid string input).
    new_pointer_lines="$(printf '%s\n' "$content" | awk '{sub(/\r$/,"")} /^- /')" ||
        deny "diff-failed" "Could not extract proposed pointer lines from the write payload — denying rather than silently skipping the line-length check."
    added_lines="$(awk '
        FNR==NR { count[$0]++; next }
        { if (count[$0] > 0) { count[$0]--; } else { print } }
    ' <(printf '%s\n' "$old_pointer_lines") <(printf '%s\n' "$new_pointer_lines") 2>/dev/null)" ||
        deny "diff-failed" "The multiset diff between old and new pointer lines failed to compute — denying rather than silently skipping the line-length check."
    if printf '%s\n' "$added_lines" | awk -v m="$LINE_MAX" '/^- /{s=$0; gsub(/[\200-\277]/,"",s); if (length(s)>m) exit 1}'; then :; else
        deny "line-too-long" "An added/changed pointer line exceeds ${LINE_MAX} chars. The index routes; it does not store — split the fact into its theme topic file."
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
