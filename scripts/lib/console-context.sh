#!/usr/bin/env bash
# Shared arming-time context-window (1m|standard) decision primitives
# (HIMMEL-2658, re-pinned by HIMMEL-2975 T6).
#
# WHY: the same decisions -- is a model Fable-family (the CLI silently
# strips a [1m] suffix there), what autocompact value a mode maps to, and
# what the DEFAULT mode is when nothing explicit was given -- used to be
# duplicated across scripts/handover/arm-resume.sh, headed-arm.sh and
# console.sh's print-only mirror. console.sh's own header called that
# duplication "deliberate ... mirrored here (not shared -- a different
# script)"; this file is what makes it genuinely shared instead, so the
# printed launch line and the actually-launched value cannot drift apart.
#
# Bash 3.2-compatible: no `local -n` namerefs (unavailable pre-4.3). Each
# function that needs to hand back more than an exit code sets a bare
# CONSOLE_CONTEXT_* global instead. Callers keep their own prose/wording --
# this file only owns the DECISION, not the human-readable reason string
# each caller logs (those strings are pinned by each caller's own test
# suite and legitimately differ between scripts) -- except the source word
# after the mode (`context=1m (explicit)`) and the durable launch-context row,
# which a reader keys on and so come from console_context_source_label /
# console_context_write_record below (HIMMEL-3282).
#
# Functions:
#   console_context_valid <value>            -- rc 0 iff value is 1m|standard
#   console_context_model_is_fable <model>   -- rc 0 iff model is Fable-family
#   console_context_has_1m_suffix <model>    -- rc 0 iff model ends in [1m]
#   console_context_strip_1m_suffix <model>  -- prints model with [1m] stripped
#   console_context_autocompact <mode>       -- prints the autocompact value
#                                                for a resolved mode
#   console_context_default <is_console> <console_context_env>
#                                             -- sets CONSOLE_CONTEXT_RESOLVED_MODE
#                                                and CONSOLE_CONTEXT_RESOLVED_SOURCE
#                                                for when no explicit value
#                                                was given
#   console_context_source_label <explicit 0|1>
#                                             -- prints explicit|default, the
#                                                source word both arms log and record
#   console_context_write_record <session> <mode> <source> <autocompact>
#                                             -- appends the durable launch-context
#                                                row (HIMMEL-3279/3282), rc 0 iff written

console_context_valid() {
    case "$1" in
        1m|standard) return 0 ;;
        *) return 1 ;;
    esac
}

# Fable-FAMILY match, not a literal string -- fable, fable-5, claude-fable-5,
# Claude-Fable-5 all match. Case-insensitive substring, same idiom every
# caller already used before this file existed.
console_context_model_is_fable() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        *fable*) return 0 ;;
        *) return 1 ;;
    esac
}

console_context_has_1m_suffix() {
    case "$1" in
        *\[1m\]) return 0 ;;
        *) return 1 ;;
    esac
}

console_context_strip_1m_suffix() {
    case "$1" in
        *\[1m\]) printf '%s' "${1%\[1m\]}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# console_context_autocompact <mode> -- prints the --autocompact value for a
# resolved mode, rc 1 on an unrecognized one (caller decides how to react;
# this file never exits the caller's process). `standard` and `1m` are the
# only values any caller's CLI/positional surface accepts today (this ticket
# adds no new one), but the parser itself stays generic on a trailing `k`
# shape -- HIMMEL-2975 T6 keeps the design doc's N3 generic <N>k resolver
# alive as the parser here even though the 400k tier it was written for is
# retired, per the v1 join design's explicit note that the shape, not the
# tier, is what survives.
console_context_autocompact() {
    case "$1" in
        1m) printf '%s' 'auto' ;;
        standard) printf '%s' '200000' ;;
        *k)
            _cc_n="${1%k}"
            case "$_cc_n" in
                ''|*[!0-9]*) return 1 ;;
            esac
            printf '%s000' "$_cc_n"
            ;;
        *) return 1 ;;
    esac
}

# console_context_default <is_console 0|1> <console_context_env value>
#
# Only for the no-explicit-value path -- a caller with an explicit
# --context/positional value never calls this. HIMMEL-2975: every arm
# defaults to `standard` now (previously a console-class arm defaulted to
# `1m`, the largest single measured saving in the cost program going
# unrealized). CONSOLE_CONTEXT=1m in the launching shell is the one
# remaining way a console-class arm opts back into 1m without an explicit
# value -- non-console callers pass is_console=0 and the env is ignored,
# same as before this file existed.
# shellcheck disable=SC2034  # output-contract globals, read by sourcing callers (arm-resume.sh, headed-arm.sh, console.sh)
console_context_default() {
    if [ "$1" -eq 1 ] && [ "$2" = "1m" ]; then
        CONSOLE_CONTEXT_RESOLVED_MODE="1m"
        CONSOLE_CONTEXT_RESOLVED_SOURCE="console-context-env"
    else
        CONSOLE_CONTEXT_RESOLVED_MODE="standard"
        CONSOLE_CONTEXT_RESOLVED_SOURCE="default"
    fi
}

# console_context_source_label <explicit_given 0|1> -- prints the source word
# both arming paths log and record: `explicit` when the mode was named
# (--context / the launcher's positional) OR opted into with CONSOLE_CONTEXT=1m
# (a 1m arm is always that opt-in, the mechanism is not lost), else `default`.
# Spec 2973 sec 2.4 keys on `context=1m (explicit)`. HIMMEL-3282: arm-resume.sh
# used to spell this from its own prose while headed-arm.sh spelled `(explicit)`,
# so a reader keying on the spec attributed one path and silently skipped the
# other; both callers take the word from here now. Read
# CONSOLE_CONTEXT_RESOLVED_SOURCE only after console_context_default ran.
console_context_source_label() {
    if [ "$1" -eq 1 ] || [ "${CONSOLE_CONTEXT_RESOLVED_SOURCE:-}" = "console-context-env" ]; then
        printf '%s' explicit
    else
        printf '%s' default
    fi
}

# console_context_write_record <session> <mode> <source> <autocompact>
#
# The durable launch-context row for a console arm (HIMMEL-3279 shipped it in
# headed-arm.sh; HIMMEL-3282 moved it here so arm-resume.sh, the Windows
# station's arming path, writes the SAME row rather than a second shape). It is
# a row in the HIMMEL-3270 launch record dir (${HIMMELCTL_CACHE_DIR:-
# $HOME/.claude/himmel}/launch-logs/<session>.log, btrfs, not the tmpfs arm log
# that a reboot erases), keyed `headed-arm:` so it cannot read as a leg's
# `headed-arm-leg:` profile line. The prefix is shared on purpose: the reader
# (sc_launch_context, spec 2973 sec 2.4) asks what mode the SESSION received,
# not which launcher armed it, and a second prefix would leave every
# arm-resume console `unknown` until each reader learns it.
#
# Best-effort: rc 0 iff the row was appended; rc 1 otherwise, and the caller
# says so in its own log (a lost record is `unknown` to the reader, never a
# proxy). A session name that is empty or carries `/` is refused here -- it is
# a filename component. Sets CONSOLE_CONTEXT_RECORD_DIR (the dir the row went,
# or would have gone, to) for the caller's warning.
# shellcheck disable=SC2034  # output-contract global, read by sourcing callers
console_context_write_record() {
    CONSOLE_CONTEXT_RECORD_DIR="${HIMMELCTL_CACHE_DIR:-}"
    [ -z "$CONSOLE_CONTEXT_RECORD_DIR" ] && [ -n "${HOME:-}" ] && CONSOLE_CONTEXT_RECORD_DIR="$HOME/.claude/himmel"
    [ -n "$CONSOLE_CONTEXT_RECORD_DIR" ] && CONSOLE_CONTEXT_RECORD_DIR="$CONSOLE_CONTEXT_RECORD_DIR/launch-logs"
    case "$1" in ""|*/*) return 1 ;; esac
    [ -n "$CONSOLE_CONTEXT_RECORD_DIR" ] || return 1
    ( umask 077 && mkdir -p "$CONSOLE_CONTEXT_RECORD_DIR" && \
        printf 'headed-arm: role=console session=%s context=%s source=%s autocompact=%s launched=%s\n' \
            "$1" "$2" "$3" "$4" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            >> "$CONSOLE_CONTEXT_RECORD_DIR/$1.log" ) 2>/dev/null
}
