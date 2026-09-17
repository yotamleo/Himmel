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
# in the first place). Returns 0 on a successful, complete scan (0 or more
# sessions); returns 3 if the scan completed but one or more matched pids had
# an unreadable (not missing) /proc/<pid>/cmdline -- HIMMEL-3002: a hidepid
# mount or a permission boundary must not read the same as "the process
# already exited," which is the ONLY case that stays silent (no row, rc 0).
# A degraded scan still prints every readable row, plus one `# unreadable
# <pid>` comment line per pid it could not read, so callers keep the rows
# they can trust while knowing the table is incomplete. Returns pgrep's own
# rc verbatim when pgrep's scan itself failed (rc>1) so a caller can tell
# "found nothing" from "the census broke" from "the census is incomplete"
# (mirrors ceiling-conformance.sh's existing pgrep-rc contract). CAVEAT:
# pgrep's own documented fatal-error rc is also 3 (e.g. OOM), forwarded
# verbatim with NO output printed first -- a caller distinguishes that from a
# genuine degraded scan (which always prints at least one row/comment before
# returning 3) by checking whether the captured output is empty, not by rc
# alone (see ceiling-conformance.sh).
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
    # value-bearing swallowed the very next real flag's value. CR round 3
    # (codex-2, Suggestion): `--system-prompt`/`--system-prompt-file` (the
    # non-append variant of the same free-text flag) was missing from this
    # list -- its value is exactly as attacker/prompt-controlled as
    # `--append-system-prompt`'s, so a value equal to the literal "-n" (or
    # "--model"/"--autocompact") hijacked the next token the same way.
    local proc="$1" pid="$2" cmdline
    cmdline="$proc/$pid/cmdline"
    # HIMMEL-3002: a missing /proc/<pid> dir means the process has already
    # exited (the ordinary pgrep-then-read race) -- silently skip it, rc 0,
    # today's behaviour. A PRESENT dir whose cmdline we cannot read (hidepid,
    # a permission boundary) is a different fact -- the session is alive but
    # opaque to us -- and must not collapse into the same silent no-row case.
    [ -d "$proc/$pid" ] || return 0
    if [ ! -r "$cmdline" ]; then
        printf '# unreadable %s\n' "$pid"
        return 3
    fi
    # HIMMEL-3008: `-r` above is a precheck, not a guarantee -- readability
    # can change before the loop's own `< "$cmdline"` redirection opens/reads
    # the file (a hidepid mount, or any race), and an open/read that fails at
    # that point (e.g. EISDIR from a path replaced by a directory) leaves the
    # loop reading nothing, indistinguishable by token count alone from a
    # zombie's genuinely-empty cmdline. Bash's `read` builtin tells the two
    # apart: a real read error prints a diagnostic to stderr; a clean EOF on
    # an empty file does not. Capture the loop's stderr to a scratch file and
    # check afterward whether anything landed there.
    local name="" model="" autocompact="" expect="" tok got_tok=0 tok_count=0
    local errfile="" read_err=0 mktemp_failed=0
    errfile="$(mktemp "${TMPDIR:-/tmp}/claude-sessions-cmdline-err.XXXXXX" 2>/dev/null)" || errfile=""
    # HIMMEL-3008 CR round 1 (codex-2, Important): a failed mktemp leaves
    # errfile empty, so the loop's stderr below falls through to /dev/null and
    # read_err can never become 1 -- an unreadable live pid would silently
    # collapse into the same "clean empty read" case this whole scratch-file
    # scheme exists to distinguish. Track the failure so it forces the same
    # unreadable/rc-3 outcome as a genuine read error, never a silent return 0.
    [ -z "$errfile" ] && mktemp_failed=1
    # HIMMEL-3008 CR round 1 (codex-1, Important): redirections apply left to
    # right, so `< "$cmdline" 2>errfile` (the prior order) let an open-time
    # failure on the `<` side (e.g. EACCES/ENOENT from a race right after the
    # `-r` precheck) print its diagnostic to the REAL stderr, before errfile
    # was even attached -- read_err stayed 0 and the pid silently vanished
    # instead of being reported. Redirecting stderr FIRST means it is already
    # pointed at errfile by the time the `<` redirection is attempted, so an
    # open-time failure is captured exactly like a read-time one (verified:
    # a nonexistent-file open under this order lands its diagnostic in
    # errfile; under the old order it escaped to real stderr).
    while IFS= read -r -d '' tok; do
        got_tok=1
        tok_count=$((tok_count + 1))
        # HIMMEL-3009 test seam: a real mid-read error (EIO after N tokens)
        # needs a block/char-special device to reproduce hermetically -- a
        # plain file's read either fully succeeds or fails at open time.
        # CLAUDE_SESSIONS_READ_FAULT_AFTER, honoured only when set, lets the
        # test suite force exactly that shape (unset in production: no
        # behaviour change). CLAUDE_SESSIONS_READ_FAULT_PID optionally scopes
        # the fault to one pid so a multi-pid scan's other rows stay real.
        if [ -n "${CLAUDE_SESSIONS_READ_FAULT_AFTER:-}" ] && [ "$tok_count" -eq "$CLAUDE_SESSIONS_READ_FAULT_AFTER" ] \
            && { [ -z "${CLAUDE_SESSIONS_READ_FAULT_PID:-}" ] || [ "$pid" = "$CLAUDE_SESSIONS_READ_FAULT_PID" ]; }; then
            echo 'read fault (test seam)' >&2
            break
        fi
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
            --system-prompt|--system-prompt-file) expect=skip ;;
        esac
    done 2>"${errfile:-/dev/null}" < "$cmdline"
    if [ -n "$errfile" ]; then
        [ -s "$errfile" ] && read_err=1
        rm -f "$errfile"
    fi
    if [ "$got_tok" -eq 0 ]; then
        # Zero tokens is ambiguous by itself: a genuinely empty cmdline (a
        # zombie -- the process still has a live /proc/<pid> entry but no
        # more argv to read) must not become a phantom empty-fields row, but
        # it is also not a readability failure -- stay silent, rc 0. A pid
        # that vanished entirely mid-read (dir gone by the time we check)
        # keeps today's silent/rc-0 vanished behaviour even if the read
        # happened to log an error on the way out. Only a live pid whose
        # read actually errored (or whose error we could not even capture --
        # mktemp_failed) is the HIMMEL-3008 race -- report it exactly like
        # the upfront `-r` failure above.
        if [ -d "$proc/$pid" ] && { [ "$read_err" -eq 1 ] || [ "$mktemp_failed" -eq 1 ]; }; then
            printf '# unreadable %s\n' "$pid"
            return 3
        fi
        return 0
    fi
    # HIMMEL-3009: at least one token was read, but the loop also errored (or
    # never got the chance to detect an error at all -- mktemp_failed) before
    # reaching a clean EOF. Falling through to the row print below would emit
    # a row built from a TRUNCATED argv -- a partial read masquerading as a
    # complete one. Mirror the zero-token branch above: a still-live pid is a
    # readability failure (unreadable, rc 3); a pid that vanished mid-read is
    # the ordinary race (silent, rc 0), not a readability failure.
    if [ "$read_err" -eq 1 ] || [ "$mktemp_failed" -eq 1 ]; then
        if [ -d "$proc/$pid" ]; then
            printf '# unreadable %s\n' "$pid"
            return 3
        fi
        return 0
    fi
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
                            # verbatim as the no-/proc fallback. NOT in scope
                            # for HIMMEL-3002: `pgrep -af` itself can't tell a
                            # permission-denied process from a vanished one
                            # either (a line it can't read just isn't in its
                            # output), so this path has the same blind spot
                            # the /proc reader used to have -- undetected here.
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

    local pids pg_rc pid degraded=0 child_rc
    pids="$("$pgrep_bin" -x claude 2>/dev/null)"
    pg_rc=$?
    [ "$pg_rc" -gt 1 ] && return "$pg_rc"
    for pid in $pids; do
        [ -n "$pid" ] || continue
        _claude_sessions_from_cmdline "$proc" "$pid"
        child_rc=$?
        [ "$child_rc" -eq 3 ] && degraded=1
    done
    [ "$degraded" -eq 1 ] && return 3
    return 0
}
