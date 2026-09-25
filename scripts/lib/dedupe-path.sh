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
    printf '%s' "${1-}" | awk -v RS=':' '!seen[$0]++ { printf "%s%s", (NR>1 ? ":" : ""), $0 }'
}
