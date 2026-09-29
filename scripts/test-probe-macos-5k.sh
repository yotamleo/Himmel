#!/usr/bin/env bash
# HIMMEL-3699 slice 5k TEMPORARY macOS probe: re-runs the leftover-red suites
# under bash -x and prints the region around each FAIL. Deleted before READY.
cd "$(dirname "$0")/.." || exit 1
for s in scripts/handover/test-arm-resume-proxy.sh \
         scripts/handover/test-arm-resume-queue-lock.sh \
         scripts/lib/test-bank-preflight.sh \
         scripts/test-quiet-run.sh; do
    echo "=== PROBE $s"
    bash -x "$s" > "${TMPDIR:-/tmp}/probe.out" 2>&1
    echo "rc=$?"
    grep -n -B25 -m2 'FAIL' "${TMPDIR:-/tmp}/probe.out" | cut -c1-300 | head -90
done
exit 1
