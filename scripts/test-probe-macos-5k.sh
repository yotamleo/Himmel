#!/usr/bin/env bash
# HIMMEL-3699 slice 5k TEMPORARY macOS probe. Deleted before READY.
cd "$(dirname "$0")/.." || exit 1
D=$(mktemp -d)
touch -t 200001010000 "$D/himmel-resume.stale.bat"
echo "=== PROBE prune TMPDIR=$D"
P=$(TMPDIR="$D" mktemp -t himmel-resume.XXXXXX.bat)
echo "=== PROBE mktemp -> $P"
find "$(dirname "$P")" -maxdepth 1 -type f -name 'himmel-resume.*.bat' -mtime +7 -delete; echo "=== PROBE find rc=$?"
ls "$D"
O=$(mktemp)
bash scripts/handover/test-arm-resume.sh --only T-wsl > "$O" 2>&1
echo "=== PROBE T-wsl rc=$?"
grep -n "wsl-prompt" "$O" | cut -c1-400 | head -8
O2=$(mktemp)
bash scripts/handover/test-arm-resume.sh --only T24 > "$O2" 2>&1
echo "=== PROBE T24 rc=$?"
grep -n -A6 "T24c" "$O2" | cut -c1-300 | head -30
exit 1
