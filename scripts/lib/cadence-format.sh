#!/usr/bin/env bash
# cadence-format.sh — shared runner-format version + staleness probe for
# generated cadence runners (HIMMEL-588/HIMMEL-969).
#
# Cadence runners (.bat/.sh) are GENERATED artifacts, baked at arm time by the
# cadence emitters. They hard-code paths/payload config and are NOT regenerated
# when the himmel code changes. So an operator who armed BEFORE a runner-format
# change keeps firing stale runners with no nudge (this is exactly what bit
# HIMMEL-575: the --settings injection only took effect after a manual
# `arm --force`).
#
# This lib is the single source of truth: WRITERS stamp
# CADENCE_RUNNER_FORMAT_VERSION into every runner at arm time, and the READERS
# (himmel-doctor C8, himmel-update post-pull nudge) probe the stamp to detect
# stale armed cadences and point the operator at the matching `arm --force`.
#
# Sourced, not executed. bash 3.2-safe; no side effects.

# Bump when a runner/fragment format change requires an ALREADY-armed cadence to
# be re-armed (--force) to take effect. Runners armed before the stamp existed
# carry no marker and read as version 0 (stale). New users (first arm after a
# bump) get the current version automatically, so they never false-positive.
#
# v2 (HIMMEL-506): per-leg --model pins injected into every runner + the
# synthesize/health frequency shift (weekly→daily, monthly→weekly). An armed
# v1 cadence still fires, but on the OLD frequencies with NO model pin (so it
# inherits the operator's saved default tier) — nudge `arm --force`.
# shellcheck disable=SC2034  # consumed by sourcing scripts (pipeline-cadence/doctor/update)
CADENCE_RUNNER_FORMAT_VERSION=2

# Marker line stamped into each generated runner
# (.bat: `rem <marker> N`; .sh: `# <marker> N`).
CADENCE_FORMAT_MARKER="himmel-cadence-runner-format:"

# Basename registry for generated cadence runners. Keep explicit: a stray
# foreign *.bat/*.sh in a runner dir must not poison the staleness probe.
# shellcheck disable=SC2034  # consumed by cadence_runner_stamp callers/tests
CADENCE_RUNNER_BASENAMES="pipeline-harvest pipeline-synthesize pipeline-health codex-sweep graphmap-luna graphmap-himmel"

# cadence_user_home
# The runner homes the EMITTERS write under key off resolve_user_home
# (HIMMEL-645: on Windows Git-Bash $HOME can be the MSYS home while
# ~/.claude lives under the Windows profile — prefer USERPROFILE via
# cygpath). READERS must resolve the same way or they probe an empty MSYS
# dir and report "no armed cadence" on exactly the machines the Windows-only
# codex-sweep cadence runs on (HIMMEL-969 codex-adv finding). Same body as
# the emitters' resolve_user_home; kept here so the readers share one copy.
cadence_user_home() {
    if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE"
    else
        printf '%s' "${HOME:-${USERPROFILE:-/tmp}}"
    fi
}

# cadence_runner_stamp <bat_dir>
# Echo the MINIMUM format version stamped across the runners under <bat_dir>
# (an unstamped runner reads as 0 — i.e. armed before HIMMEL-588). Minimum,
# not first-found: a multi-runner re-arm interrupted between writes leaves a
# mixed set, and one current runner must not mask a stale sibling
# (HIMMEL-969 codex-adv finding). Return:
#   0 — at least one runner present (version echoed on stdout)
#   1 — no runners present (cadence not armed via this dir)
cadence_runner_stamp() {
    local dir="$1" name ext f ver min=""
    for name in $CADENCE_RUNNER_BASENAMES; do
        for ext in bat sh; do
            f="$dir/$name.$ext"
            [ -f "$f" ] || continue
            ver="$(grep -oE "${CADENCE_FORMAT_MARKER}[[:space:]]*[0-9]+" "$f" 2>/dev/null \
                | head -1 | grep -oE '[0-9]+$' || true)"
            [ -n "$ver" ] || ver=0
            if [ -z "$min" ] || [ "$ver" -lt "$min" ]; then
                min="$ver"
            fi
        done
    done
    [ -n "$min" ] || return 1
    printf '%s' "$min"
    return 0
}
