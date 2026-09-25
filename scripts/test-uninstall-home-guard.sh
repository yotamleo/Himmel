#!/usr/bin/env bash
# HIMMEL-2502: test-uninstall.sh's own HOME-isolation preflight (the
# real-home-under-$TMP check + the live-operator-marker check, run before the
# hermetic PATH is built) must HARD-ABORT the suite when either check fails —
# not just log a FAIL and fall through to the wet uninstall.sh rows below it.
# A soft fail there is the exact hazard this ticket exists to close: the
# suite's only independent protection would report a problem and then run
# the wet removals anyway.
#
# Static inspection only (per the ticket's harness-safety note) — this never
# invokes uninstall.sh and never runs a wet row.
set -uo pipefail

SUITE="$(cd "$(dirname "$0")" && pwd)/test-uninstall.sh"
FAILED=0

realhome_line=$(grep -n "operator's real .*HOME resolved under this suite" "$SUITE" | head -1 | cut -d: -f1)
preflight_line=$(grep -n 'suite HOME fixture carries no live-operator marker' "$SUITE" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016 # literal $CLI text in the source file, not expansion
first_cli_line=$(grep -n 'bash "\$CLI"' "$SUITE" | head -1 | cut -d: -f1)

if [ -z "$realhome_line" ] || [ -z "$preflight_line" ] || [ -z "$first_cli_line" ]; then
    echo "FAIL could not locate the real-\$HOME-under-\$TMP check, the live-operator-marker check, or the first uninstall.sh invocation in $SUITE"
    FAILED=$((FAILED + 1))
else
    abort_line=$(awk -v lo="$preflight_line" -v hi="$first_cli_line" \
        'NR > lo && NR < hi && /FAILED" -gt 0/ {print NR; exit}' "$SUITE")
    if [ -n "$abort_line" ]; then
        # exit 1 must appear within the next 4 lines — i.e. inside the SAME
        # `if [ "$FAILED" -gt 0 ]; then ... fi` block, not some unrelated
        # later exit that would let this test PASS without the abort existing.
        exit_after=$(awk -v start="$abort_line" -v hi="$first_cli_line" \
            'NR > start && NR <= start + 4 && NR < hi && /exit 1/ {print NR; exit}' "$SUITE")
    fi
    if [ "$preflight_line" -le "$realhome_line" ]; then
        echo "FAIL the live-operator-marker check (line $preflight_line) does not follow the real-\$HOME-under-\$TMP check (line $realhome_line)"
        FAILED=$((FAILED + 1))
    elif [ -n "${abort_line:-}" ] && [ -n "${exit_after:-}" ]; then
        echo "PASS a HOME-isolation preflight failure aborts (line $abort_line) before the first uninstall.sh invocation (line $first_cli_line)"
    else
        echo "FAIL no hard abort immediately following the HOME-isolation preflight (line $realhome_line) before the first uninstall.sh invocation (line $first_cli_line) — a failed preflight falls through to a wet row"
        FAILED=$((FAILED + 1))
    fi
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILED FAILURE(S)"
    exit 1
fi
