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
# suite and legitimately differ between scripts).
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
