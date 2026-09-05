#!/usr/bin/env bash
# scripts/lib/red-control.sh -- the RED-control contract (HIMMEL-2518).
#
# A mutation control proves a test assertion is non-vacuous: build a scratch
# copy of the script under test with one line changed, run the real fixture
# against the mutant, and assert the case would have gone RED. The pattern has
# a silent failure mode -- controls written as inequality/absence checks
# ("the mutant's value differs from the correct one") are SATISFIED by a mutant
# that crashed, exited early or emitted nothing, because the empty string
# differs from everything. Such a control prints "RED confirmed" while proving
# nothing, and looks identical to one that genuinely exercised the mutation.
# Confirmed twice on 2026-09-05 (T7 in scripts/cr/test-pr-check-context.sh,
# fixed in PR #2135; case 18m in scripts/ci/test-run-shell-tests.sh).
#
# The contract a valid control must establish, all four points:
#   (a) the mutant RAN         -- its exit status is captured and asserted
#   (b) it PRODUCED a value    -- empty output is a control failure, not evidence
#   (c) the value is the SPECIFIC wrong one predicted, not merely != correct
#   (d) distinct failure messages per mode, so the next reader can tell which
#       happened: crashed / empty / wrong-mutation / genuinely-not-red
#
# Usage (two phases -- the split is deliberate: red_control_run is the only way
# to record an exit status, so point (a) cannot be skipped by forgetting to
# capture it, and the recorded run is consumed by exactly one assert):
#
#   RED_CONTROL_TMPDIR="$tmp"        # optional; where stderr capture files land
#   . "$DIR/../lib/red-control.sh"
#
#   rows_before=$(...)
#   red_control_run --cwd "$wt" --env HIMMEL_REPO="$anchor" -- bash "$mutant"
#   rows_after=$(...)
#   red_control_assert \
#     --label "T26" \
#     --observed     "delegated=$(get_kv "$RED_CONTROL_OUT" delegated) rows=$((rows_after - rows_before))" \
#     --expect-wrong "delegated=yes rows=0" \
#     --correct      "delegated=yes rows=1" \
#     --note "WITHOUT head-binding the stale-head capability IS silently accepted" \
#     || fail=1
#
# HIMMEL-2503 discipline is the caller's: mutants live in mktemp scratch copies
# only. This library never repoints a path a destructive trap consumes -- it
# creates exactly one file (the stderr capture) and never removes a directory.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure shell -- command substitution, `env`, string compare; no .ps1 twin,
# because the only consumers are shell test suites which are themselves
# gitbash-only. This is the T15 marker scripts/parity/test-ws5-invariants.sh
# looks for.
#
# Sourced, never executed. Sets no `set -e`/`set -u` of its own and exits
# nothing: every function RETURNS, so a control failure cannot abort a suite
# mid-fixture and leave scratch state behind.

# Exit statuses returned by red_control_assert -- one per contract failure
# mode, so a caller (and this library's own test) can assert WHICH mode fired
# rather than merely that something failed.
RED_CONTROL_RC_PASS=0
RED_CONTROL_RC_CRASHED=1
RED_CONTROL_RC_EMPTY=2
RED_CONTROL_RC_WRONG_MUTATION=3
RED_CONTROL_RC_NOT_RED=4
RED_CONTROL_RC_BROKEN=5

# red_control_run [--cwd DIR] [--env K=V]... [--stderr FILE] -- CMD [ARG...]
#
# Run the mutant, recording BOTH its stdout and its exit status for the assert
# that follows. Always returns 0: the run is evidence-gathering, not the
# assertion -- a mutant that crashes is a control FAILURE, reported with its
# own message by red_control_assert, not a silent early return here.
#
# Sets: RED_CONTROL_OUT (stdout, trailing newlines stripped)
#       RED_CONTROL_RC  (the mutant's exit status)
#       RED_CONTROL_ERRFILE (path to its captured stderr, shown on `crashed`)
red_control_run() {
    local cwd="" errfile=""
    local envs=()
    # Invalidate any previously recorded run FIRST, before a single thing here
    # can fail (CR round 1 [codex-1]). Every early return below is a setup
    # failure, and a caller that does not check this function's own exit status
    # would otherwise go on to assert against the PREVIOUS run's stdout with
    # RED_CONTROL_RAN still 1 — a stale-evidence pass, which is precisely the
    # class this library exists to refuse. Clearing here means a failed setup
    # degrades to `broken`, never to a silent re-read.
    RED_CONTROL_RAN=0
    RED_CONTROL_OUT=""
    RED_CONTROL_RC=""
    while [ $# -gt 0 ]; do
        # Arity guard before the dispatch (CR round 1 [codex-2]): with the
        # value missing, `shift 2` on a single remaining argument FAILS and
        # leaves "$@" untouched, so the loop spins forever on the same token —
        # an unbounded hang in a test suite, not the `broken` return the
        # contract promises. Verified: `red_control_run --cwd` hung until
        # killed at 3s before this guard.
        case "$1" in
            --cwd|--env|--stderr)
                if [ $# -lt 2 ]; then
                    printf 'red_control_run: option %s requires a value\n' "$1" >&2
                    return "$RED_CONTROL_RC_BROKEN"
                fi
                ;;
        esac
        case "$1" in
            --cwd)    cwd="$2"; shift 2 ;;
            --env)    envs+=("$2"); shift 2 ;;
            --stderr) errfile="$2"; shift 2 ;;
            --)       shift; break ;;
            *)
                printf 'red_control_run: unknown option %s\n' "$1" >&2
                return "$RED_CONTROL_RC_BROKEN"
                ;;
        esac
    done
    if [ $# -eq 0 ]; then
        printf 'red_control_run: no command given (did you forget --?)\n' >&2
        return "$RED_CONTROL_RC_BROKEN"
    fi
    [ -n "$cwd" ] || cwd="$PWD"
    if [ -z "$errfile" ]; then
        errfile="${RED_CONTROL_TMPDIR:-${TMPDIR:-/tmp}}/red-control-stderr.$$"
    fi
    if ! : > "$errfile" 2>/dev/null; then
        printf 'red_control_run: cannot write the stderr capture %s\n' "$errfile" >&2
        return "$RED_CONTROL_RC_BROKEN"
    fi
    RED_CONTROL_ERRFILE="$errfile"
    # `cd` inside the substitution, never in the caller's shell: a control must
    # not move the suite's cwd. A failed cd surfaces as a nonzero rc, i.e. the
    # `crashed` mode, with the cd error itself in the stderr capture.
    RED_CONTROL_OUT="$(cd "$cwd" && env ${envs[@]+"${envs[@]}"} "$@" 2>"$errfile")"
    RED_CONTROL_RC=$?
    RED_CONTROL_RAN=1
    return 0
}

# red_control_assert --label L --observed V --expect-wrong W
#                    [--correct C] [--expect-rc N] [--note TEXT]
#
# Enforce the four-point contract against the run recorded by the immediately
# preceding red_control_run. Prints "<label> RED confirmed: ..." and returns 0
# only when all four hold; otherwise prints one FAIL line naming the mode and
# returns that mode's status.
#
# --correct is optional but strongly recommended: without it, a mutant that
# reproduced the CORRECT value is reported as `wrong-mutation` rather than the
# more precise `genuinely-not-red`.
red_control_assert() {
    local label="" observed="" wrong="" correct="" note=""
    local expect_rc=0 have_observed=0 have_wrong=0 have_correct=0

    # Consume the recorded run FIRST — before option parsing, so that "every
    # path" is literally every path (CR round 1 [codex-3]: the unknown-option
    # arm used to return while the run was still consumable, leaving a caller
    # error able to hand its run to the NEXT assert). A second assert without
    # a fresh red_control_run is a broken control, not a re-reading of the old
    # one; that is the shape that lets a copy-pasted control silently assert
    # against the previous mutant's output.
    local ran="${RED_CONTROL_RAN:-0}"
    RED_CONTROL_RAN=0

    while [ $# -gt 0 ]; do
        # Arity guard — same reason as red_control_run's above: a missing
        # value makes `shift 2` fail and the loop spin forever.
        case "$1" in
            --label|--observed|--expect-wrong|--correct|--expect-rc|--note)
                if [ $# -lt 2 ]; then
                    printf 'FAIL: red_control_assert RED-control broken: option %s requires a value\n' "$1" >&2
                    return "$RED_CONTROL_RC_BROKEN"
                fi
                ;;
        esac
        case "$1" in
            --label)        label="$2"; shift 2 ;;
            --observed)     observed="$2"; have_observed=1; shift 2 ;;
            --expect-wrong) wrong="$2"; have_wrong=1; shift 2 ;;
            --correct)      correct="$2"; have_correct=1; shift 2 ;;
            --expect-rc)    expect_rc="$2"; shift 2 ;;
            --note)         note="$2"; shift 2 ;;
            *)
                printf 'FAIL: red_control_assert RED-control broken: unknown option %s\n' "$1" >&2
                return "$RED_CONTROL_RC_BROKEN"
                ;;
        esac
    done

    [ -n "$label" ] || label="(unlabelled)"

    if [ "$ran" != "1" ]; then
        printf 'FAIL: %s RED-control broken: assert called without a preceding red_control_run (nothing ran, so nothing is proved)\n' "$label" >&2
        return "$RED_CONTROL_RC_BROKEN"
    fi
    if [ "$have_observed" -ne 1 ] || [ "$have_wrong" -ne 1 ]; then
        printf 'FAIL: %s RED-control broken: --observed and --expect-wrong are both required (point 3 of the contract has no meaning without the specific predicted value)\n' "$label" >&2
        return "$RED_CONTROL_RC_BROKEN"
    fi
    if [ -z "$wrong" ]; then
        printf 'FAIL: %s RED-control broken: --expect-wrong is empty; the empty string is what a crashed mutant produces, so it can never BE the predicted wrong value\n' "$label" >&2
        return "$RED_CONTROL_RC_BROKEN"
    fi
    if [ "$have_correct" -eq 1 ] && [ "$correct" = "$wrong" ]; then
        printf 'FAIL: %s RED-control broken: --correct and --expect-wrong are the same value (%s); this control could never distinguish red from green\n' "$label" "$wrong" >&2
        return "$RED_CONTROL_RC_BROKEN"
    fi

    # (a) the mutant RAN.
    if [ "$RED_CONTROL_RC" != "$expect_rc" ]; then
        printf 'FAIL: %s RED-control crashed: the mutant exited %s, expected %s - a mutant that died before reaching the mutated line proves nothing%s\n' \
            "$label" "$RED_CONTROL_RC" "$expect_rc" "$(_red_control_stderr_tail)" >&2
        return "$RED_CONTROL_RC_CRASHED"
    fi

    # (b) it PRODUCED a value.
    if [ -z "$RED_CONTROL_OUT" ]; then
        printf 'FAIL: %s RED-control empty: the mutant exited %s but produced NO output; an empty value differs from every correct value, so this control would pass vacuously\n' \
            "$label" "$RED_CONTROL_RC" >&2
        return "$RED_CONTROL_RC_EMPTY"
    fi
    if [ -z "$observed" ]; then
        printf 'FAIL: %s RED-control empty: the mutant ran and printed output, but the observed value extracted from it is empty - the extraction, not the mutation, is what this control is testing\n' \
            "$label" >&2
        return "$RED_CONTROL_RC_EMPTY"
    fi

    # (c) it is the SPECIFIC wrong value predicted.
    if [ "$have_correct" -eq 1 ] && [ "$observed" = "$correct" ]; then
        printf 'FAIL: %s RED-control genuinely-not-red: the mutant produced the CORRECT value (%s) - the assertion this control claims to protect cannot tell the mutant from the real script, so it is vacuous\n' \
            "$label" "$correct" >&2
        return "$RED_CONTROL_RC_NOT_RED"
    fi
    if [ "$observed" != "$wrong" ]; then
        printf 'FAIL: %s RED-control wrong-mutation: the mutant produced %s, but the predicted wrong value was %s - this mutation is not exercising the failure mode the control claims to\n' \
            "$label" "$observed" "$wrong" >&2
        return "$RED_CONTROL_RC_WRONG_MUTATION"
    fi

    printf '%s RED confirmed: the mutant ran (rc=%s) and produced the predicted wrong value %s (the real script produces %s)%s\n' \
        "$label" "$RED_CONTROL_RC" "$observed" \
        "$([ "$have_correct" -eq 1 ] && printf '%s' "$correct" || printf 'something else')" \
        "$([ -n "$note" ] && printf ' - %s' "$note")"
    return "$RED_CONTROL_RC_PASS"
}

# _red_control_stderr_tail -- the last few stderr lines of the run, inlined
# into the `crashed` message. A crashed mutant's cause is almost always there
# (fail-closed exit 2, missing anchor, cd failure), and the whole point of a
# distinct `crashed` mode is that the reader can act on it immediately.
_red_control_stderr_tail() {
    local f="${RED_CONTROL_ERRFILE:-}"
    [ -n "$f" ] && [ -s "$f" ] || return 0
    printf ' - its stderr: %s' "$(tail -n 3 "$f" | tr '\n' '|')"
}
