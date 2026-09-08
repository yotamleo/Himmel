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
# preflight call below. Exit 11 (HIMMEL-2782 codex-1): the $LANE bank is
# exhausted (SKIPPED-BANK) - same preflight call, distinct refusal reason.
# Both are distinct from headed-arm.sh's own 0-9 exit range, since this
# wrapper never reaches headed-arm.sh in either case.
#
# --lane (HIMMEL-2782): native (default) or claudex. --lane claudex (or
# LEG_LANE=claudex in the launching shell - the flag wins if both are
# given) routes the leg through scripts/claude-codex on the codex weekly
# bank instead of the Claude subscription bank: it sets headed-arm.sh's
# HEADED_ARM_LAUNCHER to the claudex binary (seam: HEADED_ARM_LEG_CLAUDEX_BIN,
# default ../../claude-codex next to this script), turns on the `script`
# tty recorder (HEADED_ARM_RECORDER=1 - load-bearing: konsole -e output is
# otherwise lost and a silent claudex death is undiagnosable), and exports
# CLAUDEX_LANE_OK=1 + CLAUDE_CODE_EFFORT_LEVEL=${LEG_EFFORT:-medium} into the
# launched process via HEADED_ARM_LAUNCHER_ENV. An empty/omitted MODEL
# defaults to gpt-6-astra for this lane (native's own default,
# claude-fable-5-1, is a Claude tier and would defeat the point of
# switching lanes). Context stays this wrapper's normal standard/1m pin
# (LEG_CONTEXT=1m still applies) - standard resolves to
# --autocompact 200000, which is the leg's ceiling; scripts/claude-codex's
# own CLAUDE_CODE_AUTO_COMPACT_WINDOW=272000 default never applies because
# `exec claude "$@"` forwards the CLI flag, which wins. An unknown lane
# name is a usage error (exit 2), not a silent fallback to native.
set -u

usage() {
    echo "usage: headed-arm-leg.sh [--dry-run] [--lane native|claudex] <session-name> <handover-doc> <signal-file> <deadline-epoch> <log> [model]" >&2
}

DRY_RUN=0
LANE="${LEG_LANE:-native}"
while :; do
    case "${1:-}" in
        --dry-run) DRY_RUN=1; shift ;;
        --lane)
            # codex CR fix: `--lane` as the LAST arg leaves only 1 positional,
            # so `shift 2` fails (rc=1) and shifts NOTHING under `set -u`
            # (no `set -e` here to catch it) - the case above then matches
            # `--lane` again forever. Require a value before consuming it.
            if [ "$#" -lt 2 ]; then
                usage
                echo "headed-arm-leg: --lane requires a value (native or claudex)" >&2
                exit 2
            fi
            LANE="$2"; shift 2 ;;
        *) break ;;
    esac
done

case "$LANE" in
    native|claudex) ;;
    *)
        usage
        echo "headed-arm-leg: unknown lane: $LANE (expected native or claudex)" >&2
        exit 2
        ;;
esac

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

# claudex lane (HIMMEL-2782): see the --lane header comment above.
if [ "$LANE" = "claudex" ]; then
    CLAUDEX_BIN="${HEADED_ARM_LEG_CLAUDEX_BIN:-$HERE/../../claude-codex}"
    export HEADED_ARM_LAUNCHER="$CLAUDEX_BIN"
    export HEADED_ARM_LAUNCHER_ENV="CLAUDEX_LANE_OK=1 CLAUDE_CODE_EFFORT_LEVEL=${LEG_EFFORT:-medium}"
    export HEADED_ARM_RECORDER=1
    [ -z "$MODEL" ] && MODEL="gpt-6-astra"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf 'headed-arm-leg: would exec: %s %s %s %s %s %s %s %s\n' \
        "$HEADED_ARM" "$NAME" "$DOC" "$SIGNAL" "$DEADLINE" "$LOG" "$MODEL" "$CONTEXT"
    printf 'headed-arm-leg: env IMPL_GUARD_OK=%s HEADED_ARM_REPO=%s\n' \
        "$IMPL_GUARD_OK" "${HEADED_ARM_REPO:-<derived by headed-arm.sh>}"
    printf 'headed-arm-leg: lane=%s launcher=%s launcher-env=%s\n' \
        "$LANE" "${HEADED_ARM_LAUNCHER:-claude (native default)}" "${HEADED_ARM_LAUNCHER_ENV:-<none>}"
    exit 0
fi

# HIMMEL-2765: fleet-size cap. Checked at ARM time, before headed-arm.sh's own
# signal/deadline wait loop even starts - refusing now is cheaper than
# refusing after waiting out the deadline. SKIPPED-FLEET refuses the launch
# outright. SKIPPED-BANK (HIMMEL-2782 codex-1 CR fix) also refuses: we set
# CADENCE_BANK_LANE="$LANE" above specifically so bank-preflight.sh checks
# the bank this lane actually draws on (the codex weekly bank for claudex,
# the CLAUDE five_hour/seven_day bank for native) - unlike arm-resume.sh,
# this wrapper has no separate bank-aware scheduling path to fall back on,
# so ignoring SKIPPED-BANK would let a launch through against an exhausted
# bank. Any other verdict (PROCEED, BANK-STALE, BANK-UNKNOWN) falls through.
BANK_PREFLIGHT="${HEADED_ARM_LEG_PREFLIGHT:-$HERE/../../lib/bank-preflight.sh}"
if [ -f "$BANK_PREFLIGHT" ]; then
    # HIMMEL-2789: this call launches a leg, so it declares launch intent —
    # the fleet cap must be able to actually refuse it, unlike a plain
    # bank-status READ.
    preflight_token="$(CADENCE_BANK_LEG="$NAME" CADENCE_BANK_LANE="$LANE" CADENCE_BANK_LAUNCH=1 bash "$BANK_PREFLIGHT" 2>>"$LOG")"
    if [ "$preflight_token" = SKIPPED-FLEET ]; then
        echo "$(date +%F_%T) headed-arm-leg: refusing to launch $NAME - fleet-size cap reached (bypass: FLEET_CAP_OK=1 in the LAUNCHING shell)" >> "$LOG"
        exit 10
    fi
    if [ "$preflight_token" = SKIPPED-BANK ]; then
        echo "$(date +%F_%T) headed-arm-leg: refusing to launch $NAME - $LANE lane bank exhausted (park and retry later; see bank-preflight.sh for the parked lane's own bank status)" >> "$LOG"
        exit 11
    fi
fi

exec "$HEADED_ARM" "$NAME" "$DOC" "$SIGNAL" "$DEADLINE" "$LOG" "$MODEL" "$CONTEXT"
