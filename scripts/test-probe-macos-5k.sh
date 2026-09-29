#!/usr/bin/env bash
# HIMMEL-3699 slice 5k TEMPORARY macOS probe. Deleted before READY.
cd "$(dirname "$0")/.." || exit 1
O=$(mktemp)
for s in handover/test-arm-resume-fast.sh handover/test-arm-resume-proxy.sh \
         handover/test-arm-resume-queue-lock.sh ci/test-os-verify-workflow.sh; do
  bash "scripts/$s" > "$O" 2>&1
  echo "=== PROBE $s rc=$?"
  grep -n -i "^FAIL\|^not ok\|FAIL -\|FAILED" "$O" | grep -v "FAILED=0\|FAIL=0" | cut -c1-260 | head -8
done
exit 1
