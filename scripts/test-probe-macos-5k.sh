#!/usr/bin/env bash
# HIMMEL-3699 slice 5k TEMPORARY macOS probe. Deleted before READY.
cd "$(dirname "$0")/.." || exit 1
O=$(mktemp)
bash scripts/handover/test-arm-resume.sh --only T-wsl > "$O" 2>&1
echo "=== PROBE T-wsl rc=$?"
grep -n "FAIL" "$O" | cut -c1-200 | head -6
grep -n -o ".\{60\}wsl-prompt.\{60\}" "$O" | head -6
exit 1
