#!/usr/bin/env bash
# scripts/handover/console-kit/leg-event.sh - route one leg message to the
# one-shot that handles it, or say ESCALATE. A script, never a model: the
# console runs it once per leg message instead of spending the several
# full-context turns the hand sequence takes.
#
# Usage: leg-event.sh --doc <console doc> --fleet <manifest> <message-file | ->
#
#   MERGED / WRAPPED  -> wrap-merged.sh --doc <doc> --fleet <manifest> <leg doc> [--pr <n>]
#                        The leg doc is the manifest entry whose name carries the
#                        message's N<k> label; <n> is the PR in a `MERGED #<n>` line.
#                        A WRAPPED line that mentions deferred, follow-up or residual with
#                        no HIMMEL-<n> key or `no-ticket: <reason>` (residual-lines.sh)
#                        is ESCALATE unfiled-residual: <line>, before wrap-merged runs.
#   anything else     -> ESCALATE (READY and FINDING need a judge or the console)
#
#   after a MERGED with a PR, station-sync.sh --pr <n> runs detached to bring the
#   station back to main: ` station=pending log=<file>` is appended at once, its
#   output goes to the log and its verdict to the state file tick.sh shows.
#
# The leg is found by its N<k> label, else by its session name (the leg doc's
# stem) quoted in the message. After a handled event the script runs
# live-state.sh <doc>, which rewrites the `## Live state` legs: line; its failure
# is appended as ` live-state=failed <why>` (the wrap is done, so rc stays 0).
#
# Output: one line. `HANDLED wrap-merged <label>[ station=pending log=<file>][ live-state=failed <why>]` (rc 0) or
# `ESCALATE <reason>` (rc 10), the reason being no-label, not-in-manifest,
# marker-<X>, unfiled-residual: <line>, or wrap-merged-failed rc=<n> with wrap-merged's stderr after it.
# Usage errors exit 2 before anything runs.
#
# Test seams (env): LE_WRAP LE_LIST LE_LIVE LE_STATION LE_STATION_LOG.
# Platform guard: Linux bash 3.2+ (wrap-merged.sh needs flock + jq).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/handover/console-kit/residual-lines.sh
. "$HERE/residual-lines.sh"
if [ -n "${LE_WRAP:-}" ]; then WRAP=("$LE_WRAP"); else WRAP=(bash "$HERE/wrap-merged.sh"); fi
if [ -n "${LE_STATION:-}" ]; then STATION=("$LE_STATION"); else STATION=(bash "$HERE/station-sync.sh"); fi
if [ -n "${LE_LIVE:-}" ]; then LIVE=("$LE_LIVE"); else LIVE=(bash "$HERE/live-state.sh"); fi
if [ -n "${LE_LIST:-}" ]; then LIST=("$LE_LIST"); else LIST=(bash "$HERE/fleet-manifest.sh" list); fi

usage() { echo "usage: leg-event.sh --doc <console doc> --fleet <manifest> <message-file | ->" >&2; exit 2; }
escalate() { echo "ESCALATE $1"; exit 10; }

DOC=""; FLEET=""; MSG=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc|--fleet) [ "$#" -ge 2 ] || usage
            case "$1" in --doc) DOC="$2" ;; --fleet) FLEET="$2" ;; esac
            shift 2 ;;
        -) [ -z "$MSG" ] || usage; MSG="-"; shift ;;
        -*) usage ;;
        *) [ -z "$MSG" ] || usage; MSG="$1"; shift ;;
    esac
done
if [ -z "$DOC" ] || [ -z "$FLEET" ] || [ -z "$MSG" ]; then usage; fi

if [ "$MSG" = "-" ]; then body="$(cat)"; else body="$(cat "$MSG")" || usage; fi
line="$(printf '%s\n' "$body" | grep -m1 -E '[^[:space:]]')" || line=""
line="${line#- }"
# a message may lead with its own N<k> label and ticket key before the marker
while [[ "$line" =~ ^(N[0-9]+|[A-Z]+-[0-9]+)[[:space:]]+ ]]; do line="${line#"${BASH_REMATCH[0]}"}"; done
marker="${line%%[^A-Za-z-]*}"

case "$marker" in
    MERGED|WRAPPED) ;;
    *) escalate "marker-${marker:-none}" ;;
esac

if [ "$marker" = WRAPPED ]; then
    mf="$(mktemp "${TMPDIR:-/tmp}/leg-event-msg.XXXXXX")" || escalate "wrap-merged-failed rc=1 mktemp"
    printf '%s\n' "$body" > "$mf"
    unfiled="$(unfiled_residual_mention_lines "$mf")"
    rm -f "$mf"
    if [ -n "$unfiled" ]; then
        escalate "unfiled-residual: $(printf '%s' "$unfiled" | tr '\n' ' ')"
    fi
fi

# the leg is named by its N<k> label, or failing that by its session name (the
# leg doc's stem, which a wrap message may quote without any N<k>)
labels="$(printf '%s\n' "$body" | grep -oE '\<N[0-9]+\>' | sort -u)" || labels=""
if [ -n "$labels" ]; then
    [ "$(printf '%s\n' "$labels" | wc -l)" -eq 1 ] || escalate "ambiguous-label"
    label="$labels"
    leg="$("${LIST[@]}" "$FLEET" 2>/dev/null | grep -F -- "-${label}-" | head -n 1)" || leg=""
    [ -n "$leg" ] || escalate "not-in-manifest $label"
else
    legs=""
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        stem="${cand##*/}"; stem="${stem%.md}"
        # the stem must stand alone: a longer, unlisted session name never matches a listed one
        [[ $body =~ (^|[^A-Za-z0-9_-])"$stem"([^A-Za-z0-9_-]|$) ]] && legs="$legs$cand"$'\n'
    done <<EOF
$("${LIST[@]}" "$FLEET" 2>/dev/null)
EOF
    [ -n "$legs" ] || escalate "no-label"
    [ "$(printf '%s' "$legs" | wc -l)" -eq 1 ] || escalate "ambiguous-label"
    leg="${legs%$'\n'}"
    stem="${leg##*/}"; stem="${stem%.md}"
    label="$stem"
    [[ $stem =~ -(N[0-9]+)- ]] && label="${BASH_REMATCH[1]}"
fi

pr=""
if [ "$marker" = MERGED ]; then
    pr="$(printf '%s\n' "$line" | grep -oE 'MERGED #?[0-9]+' | grep -oE '[0-9]+' | head -n 1)" || pr=""
fi

args=(--doc "$DOC" --fleet "$FLEET" "$leg")
[ -z "$pr" ] || args+=(--pr "$pr")
errf="$(mktemp "${TMPDIR:-/tmp}/leg-event.XXXXXX")" || escalate "wrap-merged-failed rc=1 mktemp"
"${WRAP[@]}" "${args[@]}" >/dev/null 2>"$errf"; rc=$?
if [ "$rc" -ne 0 ]; then
    msg="$(tr '\n' ' ' <"$errf")"
    rm -f "$errf"
    escalate "wrap-merged-failed rc=$rc $msg"
fi
rm -f "$errf"
# A merged PR leaves the station behind main until its components are updated:
# station-sync.sh runs the matching himmel-update steps and checks --versions. Those
# fetch and rebuild without a bound, so it runs detached: the line returns at once
# with station=pending, the sync's output (STEP, LOCAL-DIFF, STATION=) goes to the
# log, and its verdict lands in the state file tick.sh reads as station=.
station=""
if [ -n "$pr" ]; then
    slog="${LE_STATION_LOG:-$HOME/.himmel/state/station-sync.out}"
    mkdir -p "$(dirname "$slog")" 2>/dev/null || true
    setsid "${STATION[@]}" --pr "$pr" >>"$slog" 2>&1 </dev/null &
    station=" station=pending log=$slog"
fi
# re-render the legs: line so a wrapped leg is dropped by the script, not by a console Edit turn
live=""
if ! lerr="$("${LIVE[@]}" "$DOC" 2>&1 >/dev/null)"; then
    live=" live-state=failed $(printf '%s' "$lerr" | tr '\n' ' ')"
fi
echo "HANDLED wrap-merged $label$station$live"
