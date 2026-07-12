#!/usr/bin/env bash
# cadence-format.sh — shared runner-format version + staleness probe for the
# pipeline cadence (HIMMEL-588).
#
# The pipeline-cadence runners (.bat/.sh) and the cadence-settings.json fragment
# are GENERATED artifacts, baked at arm time (scripts/luna/pipeline-cadence.sh).
# They hard-code paths, the prompt, and (since HIMMEL-575) the --settings
# auto-approve injection — and they are NOT regenerated when the himmel code
# changes. So an operator who armed BEFORE a runner-format change keeps firing
# stale runners with no nudge (this is exactly what bit HIMMEL-575: the
# --settings injection only took effect after a manual `arm --force`).
#
# This lib is the single source of truth: the WRITER (pipeline-cadence.sh) stamps
# CADENCE_RUNNER_FORMAT_VERSION into every runner at arm time, and the READERS
# (himmel-doctor C8, himmel-update post-pull nudge) probe the stamp to detect a
# stale armed cadence and point the operator at `/pipeline-cadence arm --force`.
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

# cadence_runner_stamp <bat_dir>
# Echo the format version stamped in the runners under <bat_dir> (0 when runners
# exist but carry no stamp — i.e. armed before HIMMEL-588). Return:
#   0 — at least one runner present (version echoed on stdout)
#   1 — no runners present (cadence not armed via this dir)
cadence_runner_stamp() {
    local dir="$1" f ver
    for f in "$dir"/pipeline-harvest.bat "$dir"/pipeline-synthesize.bat \
             "$dir"/pipeline-health.bat "$dir"/pipeline-harvest.sh \
             "$dir"/pipeline-synthesize.sh "$dir"/pipeline-health.sh; do
        [ -f "$f" ] || continue
        ver="$(grep -oE "${CADENCE_FORMAT_MARKER}[[:space:]]*[0-9]+" "$f" 2>/dev/null \
            | head -1 | grep -oE '[0-9]+$' || true)"
        [ -n "$ver" ] || ver=0
        printf '%s' "$ver"
        return 0
    done
    return 1
}
