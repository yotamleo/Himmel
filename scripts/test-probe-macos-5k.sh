#!/usr/bin/env bash
# HIMMEL-3699 slice 5k TEMPORARY macOS probe. Deleted before READY.
cd "$(dirname "$0")/.." || exit 1
R=$PWD
T=$(mktemp -d)
mkdir -p "$T/fake/scripts/handover" "$T/fake/scripts/lib" "$T/ho/handovers/X"
cp scripts/handover/arm-resume.sh "$T/fake/scripts/handover/"
cp scripts/lib/*.sh "$T/fake/scripts/lib/"
printf -- '---\nsession_kind: test\n---\n# t\n' > "$T/ho/handovers/X/n.md"
echo "=== PROBE isolated arm-resume dry-run (bash -x tail)"
HANDOVER_DIR="$T/ho/handovers" bash -x "$T/fake/scripts/handover/arm-resume.sh" \
    --time "$(date -v+30M +%H:%M 2>/dev/null || date -d '+30 min' +%H:%M)" --handover "$T/ho/handovers/X/n.md" --dry-run > "$T/out" 2>&1
echo "rc=$? lines=$(wc -l < "$T/out")"
tail -45 "$T/out" | cut -c1-220
exit 1
