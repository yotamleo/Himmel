#!/usr/bin/env bash
# scripts/handover/console-kit/headed-arm-leg.sh - versioned LEG launcher
# (HIMMEL-2766). A thin wrapper around scripts/handover/headed-arm.sh that
# pins every leg arm to the standard (200k-autocompact) context mode - the
# window itself measures 1M regardless (docs/internals/lane-calibration.md
# "What a plain launch reports") - and adds the leg-only env the console
# lane does not need.
#
# WHY (console correction 12:1x on HIMMEL-2766, on the ticket): legs were
# ALREADY on the standard window today - the HIMMEL-2658 mechanism is the
# model-id suffix (`<model>[1m]` + `--autocompact auto` = 1M; no suffix =
# standard - see docs/internals/lane-calibration.md "Context mode" and
# headed-arm.sh's own --context handling, which this wrapper reuses rather
# than forking). What was missing was a PIN: this wrapper's own RESOLVED
# --context argument to headed-arm.sh can never be 1m unless the launching
# shell explicitly opts in. That opt-in is LEG_CONTEXT=1m - nothing else
# (not a flag, not a config file) - so a leg brief can quote the rule
# verbatim and a reviewer can grep for it. It governs the resolved context,
# not the raw model string: a caller handing this wrapper an
# already-[1m]-suffixed model gets it forwarded unchanged regardless of
# LEG_CONTEXT - stripping a literal suffix is headed-arm.sh's own contract,
# not this wrapper's (test-headed-arm-leg.sh asserts this end-to-end).
#
# Folds the two prior ad-hoc kit-local copies (headed-arm-leg.sh,
# headed-arm-leg-cwd.sh - identical except an LEG_REPO override) into ONE
# versioned script: LEG_REPO now maps onto headed-arm.sh's own
# HEADED_ARM_REPO seam instead of a second, parallel repo-root variable.
#
# Usage: headed-arm-leg.sh [--dry-run] <session-name> <handover-doc> \
#                           <signal-file> <deadline-epoch> <log> [model]
# Run detached, same as headed-arm.sh itself:
#   setsid nohup bash headed-arm-leg.sh ... >/dev/null 2>&1 &
#
# --dry-run: prints the argv this would hand to headed-arm.sh (name, doc,
# signal, deadline, log, model, resolved context) plus the leg env this
# wrapper adds, and exits 0 without touching the signal/deadline wait loop,
# the claim lock, or konsole. The test seam - but not the ONLY proof: the
# suite also drives the real (non-dry) path with KONSOLE_CMD/PGREP_CMD stubs
# (the same seams headed-arm.sh's own suite uses) to confirm the launched
# argv matches what --dry-run predicted.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, same as headed-arm.sh
# itself (konsole is Linux/KDE-only) - no .ps1 twin; the Windows station
# arms through arm-resume.sh's schtasks backend instead.
#
# Seams: HEADED_ARM_LEG_TARGET overrides the headed-arm.sh path this wrapper
# execs (default: ../headed-arm.sh next to this script) so a suite can point
# it at a fixture without touching PATH. HEADED_ARM_LEG_PREFLIGHT overrides
# the scripts/lib/bank-preflight.sh path the fleet-size cap below calls
# (default: ../../lib/bank-preflight.sh next to this script), same reason.
#
# Exit 10 (HIMMEL-2765): the fleet-size cap refused the launch - see the
# preflight call below. Distinct from headed-arm.sh's own 0-9 exit range,
# since this wrapper never reaches headed-arm.sh in that case.
set -u

usage() {
    echo "usage: headed-arm-leg.sh [--dry-run] <session-name> <handover-doc> <signal-file> <deadline-epoch> <log> [model]" >&2
}

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi

if [ "$#" -lt 5 ]; then
    usage
    exit 2
fi

NAME="$1"; DOC="$2"; SIGNAL="$3"; DEADLINE="$4"; LOG="$5"; MODEL="${6:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
HEADED_ARM="${HEADED_ARM_LEG_TARGET:-$HERE/../headed-arm.sh}"

# Context pin (HIMMEL-2766): standard by default; 1m ONLY when the
# LAUNCHING shell set LEG_CONTEXT=1m exactly. Any other value (unset,
# empty, "standard", a typo) stays on standard - fail toward the cheaper,
# already-correct default rather than toward the expensive one.
if [ "${LEG_CONTEXT:-}" = "1m" ]; then
    CONTEXT="1m"
else
    CONTEXT="standard"
fi

# LEG_REPO folds onto headed-arm.sh's own HEADED_ARM_REPO override seam -
# the one thing the two prior kit-local copies differed on.
if [ -n "${LEG_REPO:-}" ]; then
    HEADED_ARM_REPO="$LEG_REPO"
    export HEADED_ARM_REPO
fi

# IMPL_GUARD_OK=1: the leg-only env headed-arm.sh's own child-env block
# (shared with the console lane) does not set. Exported into THIS process's
# environment so it survives unchanged through konsole's `-e env -u ...`
# invocation inside headed-arm.sh, which only unsets the three HIMMEL-2545
# vars and otherwise inherits its own environment as-is.
export IMPL_GUARD_OK=1

if [ "$DRY_RUN" -eq 1 ]; then
    printf 'headed-arm-leg: would exec: %s %s %s %s %s %s %s %s\n' \
        "$HEADED_ARM" "$NAME" "$DOC" "$SIGNAL" "$DEADLINE" "$LOG" "$MODEL" "$CONTEXT"
    printf 'headed-arm-leg: env IMPL_GUARD_OK=%s HEADED_ARM_REPO=%s\n' \
        "$IMPL_GUARD_OK" "${HEADED_ARM_REPO:-<derived by headed-arm.sh>}"
    exit 0
fi

# HIMMEL-2765: fleet-size cap. Checked at ARM time, before headed-arm.sh's own
# signal/deadline wait loop even starts - refusing now is cheaper than
# refusing after waiting out the deadline. Only the SKIPPED-FLEET token
# refuses the launch; any other bank-preflight.sh verdict (PROCEED,
# SKIPPED-BANK, BANK-STALE, BANK-UNKNOWN) is out of scope for this wrapper
# and falls through - bank gating for legs is not this ticket's concern.
BANK_PREFLIGHT="${HEADED_ARM_LEG_PREFLIGHT:-$HERE/../../lib/bank-preflight.sh}"
if [ -f "$BANK_PREFLIGHT" ]; then
    preflight_token="$(CADENCE_BANK_LEG="$NAME" bash "$BANK_PREFLIGHT" 2>>"$LOG")"
    if [ "$preflight_token" = SKIPPED-FLEET ]; then
        echo "$(date +%F_%T) headed-arm-leg: refusing to launch $NAME - fleet-size cap reached (bypass: FLEET_CAP_OK=1 in the LAUNCHING shell)" >> "$LOG"
        exit 10
    fi
fi

exec "$HEADED_ARM" "$NAME" "$DOC" "$SIGNAL" "$DEADLINE" "$LOG" "$MODEL" "$CONTEXT"
