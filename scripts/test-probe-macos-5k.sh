#!/usr/bin/env bash
# HIMMEL-3699 slice 5k TEMPORARY macOS probe. Deleted before READY.
cd "$(dirname "$0")/.." || exit 1
D=$(mktemp -d)
echo "=== PROBE mktemp-nosuffix-template: $(TMPDIR="$D" mktemp "$D/himmel-resume.XXXXXX.bat" 2>&1)"
ls "$D"
echo "=== PROBE mktemp -t under TMPDIR=$D: $(TMPDIR="$D" mktemp -t himmel-resume.XXXXXX.bat 2>&1)"
O=$(mktemp)
bash scripts/handover/test-arm-resume.sh --only T-wsl > "$O" 2>&1
echo "=== PROBE T-wsl rc=$?"
grep -c . "$O"
grep -n "escaping\|wsl-prompt\|WSL escaping" "$O" | cut -c1-300 | head
echo "=== PROBE T-wsl full"
head -c 3500 "$O"
exit 1
