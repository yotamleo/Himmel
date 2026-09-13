#!/usr/bin/env bash
# scripts/lanes/lib/claude-sessions.sh - HIMMEL-2999: read every live claude
# session's real argv boundaries instead of the flattened `pgrep -af` line
# tick.sh and ceiling-conformance.sh used to scan. Free-text argv (a
# -p/--append-system-prompt value containing the literal substring "-n X" or
# "--autocompact 200000") could overwrite the real name/model/ceiling because
# the old scan walked whitespace-split tokens over the WHOLE joined line,
# last-match-wins. /proc/<pid>/cmdline is the real NUL-separated argv - a
# free-text value is exactly one element there, so it can never look like a
# "-n"/"--model"/"--autocompact" flag token no matter what it contains.
# Sourced, not run (house shape: see burn-weights.sh).
#
# Where /proc is absent (macOS, git-bash) there is no real-argv source to
# read, so this falls back to the old flattened `pgrep -af` scan and prints a
# leading "# lossy" comment line so callers can flag the degraded read.
# CLAUDE_SESSIONS_PROC overrides the procfs root (default: /proc), same seam
# shape as HEADED_ARM_PROC in headed-arm.sh; CLAUDE_SESSIONS_PGREP overrides
# the pgrep binary, for hermetic PATH-stub tests.
#
# claude_sessions - prints one TAB-separated "pid<TAB>name<TAB>model<TAB>
# autocompact" line per live claude session (a field is empty when the flag
# is absent from that session's argv), pids from `pgrep -x claude` (comm-
# exact, no -a/-f: argv is read separately per pid, so it is never flattened
# in the first place). Returns 0 on a successful scan (0 or more sessions);
# returns pgrep's own rc when pgrep's scan itself failed (rc>1) so a caller
# can tell "found nothing" from "the scan broke" (mirrors ceiling-
# conformance.sh's existing pgrep-rc contract).
#
# Platform guard: no .ps1 twin, by design -- Linux-only when /proc exists;
# the lossy fallback keeps the previous cross-platform pgrep -af behavior.
# Bash 3.2-compatible: no mapfile, no associative arrays.

_claude_sessions_from_cmdline() { # _claude_sessions_from_cmdline <proc-root> <pid>
    # Reads NUL-delimited argv elements directly (`read -d ''`) rather than
    # via `tr '\0' '\n'` + newline-`read` -- HIMMEL-2999 CR round 1 (codex-1,
    # Critical): the tr conversion is itself lossy when an argv element (an
    # --append-system-prompt value) contains a literal embedded newline
    # byte -- that byte becomes indistinguishable from a real argv-element
    # boundary once translated, letting one prompt element split into fake
    # tokens. Reading the NUL delimiter directly has no such collision.
    #
    # `expect` tracks "the NEXT token is this flag's value" and is cleared
    # the instant that one token is consumed -- HIMMEL-2999 CR round 1
    # (codex-2, Important): the old code classified every token by whether
    # the PREVIOUS token's literal text was "-n"/"--model"/"--autocompact",
    # with no notion of "that previous token was itself already consumed as
    # another flag's value." A value-bearing flag whose value happens to be
    # exactly "-n" (or "--model"/"--autocompact") then poisoned the very
    # next argv element -- a positional prompt, or another flag -- into
    # being misread as that flag's value. `expect=skip` consumes and
    # discards the value of every OTHER known value-bearing flag so its
    # value token is never re-examined; `--` ends flag parsing entirely
    # (everything after belongs to the trailing prompt). `-p`/`--print` is
    # deliberately NOT in that list -- CR round 2 (codex-1, Important): it
    # is a bare boolean flag in this repo's real invocations (see
    # scripts/probes/claude-p/*.sh -- `-p` always sits right after the
    # binary name with no value of its own), and treating it as
    # value-bearing swallowed the very next real flag's value.
    local proc="$1" pid="$2" cmdline
    cmdline="$proc/$pid/cmdline"
    [ -r "$cmdline" ] || return 0
    local name="" model="" autocompact="" expect="" tok
    while IFS= read -r -d '' tok; do
        if [ -n "$expect" ]; then
            case "$expect" in
                name) name="$tok" ;;
                model) model="$tok" ;;
                autocompact) autocompact="$tok" ;;
            esac
            expect=""
            continue
        fi
        case "$tok" in
            --) break ;;
            -n) expect=name ;;
            --model) expect=model ;;
            --autocompact) expect=autocompact ;;
            --append-system-prompt|--append-system-prompt-file) expect=skip ;;
        esac
    done < "$cmdline"
    printf '%s\t%s\t%s\t%s\n' "$pid" "$(_tsv_field "$name")" "$(_tsv_field "$model")" "$(_tsv_field "$autocompact")"
}

_tsv_field() { # _tsv_field <value> - CR round 2 (codex-2, Suggestion): a
               # field value carrying a literal TAB or newline would widen
               # or split the emitted row for every downstream awk -F'\t'
               # reader; a leg/model/ceiling value never legitimately needs
               # either byte, so both are replaced with a space.
    local v="$1"
    v="${v//$'\t'/ }"
    printf '%s' "${v//$'\n'/ }"
}

_claude_sessions_lossy() { # _claude_sessions_lossy <pgrep-bin> - the old
                            # pre-HIMMEL-2999 flattened-line scan, kept
                            # verbatim as the no-/proc fallback.
    local pgrep_bin="$1" proc_out pg_rc
    proc_out="$("$pgrep_bin" -af 'claude' 2>/dev/null)"
    pg_rc=$?
    [ "$pg_rc" -gt 1 ] && return "$pg_rc"
    echo '# lossy'
    printf '%s\n' "$proc_out" | awk '
/claude / {
    pid = $1; name = ""; model = ""; ceiling = ""
    for (i = 2; i <= NF; i++) {
        if ($i == "-n" && (i + 1) <= NF) name = $(i + 1)
        if ($i == "--model" && (i + 1) <= NF) model = $(i + 1)
        if ($i == "--autocompact" && (i + 1) <= NF) ceiling = $(i + 1)
    }
    print pid "\t" name "\t" model "\t" ceiling
}'
    return 0
}

claude_sessions() {
    local proc="${CLAUDE_SESSIONS_PROC:-/proc}"
    local pgrep_bin="${CLAUDE_SESSIONS_PGREP:-pgrep}"

    if [ ! -d "$proc" ]; then
        _claude_sessions_lossy "$pgrep_bin"
        return $?
    fi

    local pids pg_rc pid
    pids="$("$pgrep_bin" -x claude 2>/dev/null)"
    pg_rc=$?
    [ "$pg_rc" -gt 1 ] && return "$pg_rc"
    for pid in $pids; do
        [ -n "$pid" ] || continue
        _claude_sessions_from_cmdline "$proc" "$pid"
    done
    return 0
}
