# shellcheck shell=bash
# scripts/lib/dedupe-path.sh
#
# Order-preserving PATH dedupe (HIMMEL-3640). Claude Code prepends each
# enabled plugin's bin/ dir onto PATH at process startup without checking
# whether it's already present. A himmel-owned launch chokepoint that hands
# an inherited (already 2x'd) PATH straight to a nested `claude`/`claude -p`
# lets that duplication compound across every himmel-driven hop instead of
# staying at the single upstream-added copy. Sourcing this and calling
# dedupe_path right before each such launch collapses repeats so the next
# hop starts from a clean baseline — it does not (and cannot) stop Claude
# Code's own one-time-per-start injection, only the compounding across OUR
# OWN relaunches.
#
# Usage: source this file, then:
#   deduped="$(dedupe_path "$PATH")"
#
# Keeps the FIRST occurrence of each entry, in its original position. A
# colon-separated string with no duplicates round-trips unchanged (same
# bytes, same order) — required so applying this at a chokepoint is a true
# no-op on an already-clean PATH.

dedupe_path() {
    awk -F: '
    {
        cnt = 0
        for (i = 1; i <= NF; i++) {
            entry = $i
            if (!(entry in seen)) {
                seen[entry] = 1
                if (cnt++ > 0) printf ":"
                printf "%s", entry
            }
        }
    }' <<< "${1-}"
}
