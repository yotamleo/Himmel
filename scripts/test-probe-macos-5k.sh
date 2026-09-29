#!/usr/bin/env bash
# HIMMEL-3699 slice 5k TEMPORARY macOS probe. Deleted before READY.
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
mkdir -p "$T/L/scripts/handover" "$T/L/scripts/lib" "$T/ho/handovers/X" "$T/stub"
cp scripts/handover/arm-resume.sh "$T/L/scripts/handover/"
cp scripts/lib/*.sh "$T/L/scripts/lib/"
rm -f "$T/L/scripts/lib/headroom-proxy.sh"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/claude"; chmod +x "$T/stub/claude"
printf -- '---\nsession_kind: test\n---\n# t\n' > "$T/ho/handovers/X/n.md"
TM=$(date -v+30M +%H:%M 2>/dev/null || date -d '+30 min' +%H:%M)
PATH="$T/stub:$PATH" HANDOVER_DIR="$T/ho/handovers" bash -x "$T/L/scripts/handover/arm-resume.sh" \
    --time "$TM" --handover "$T/ho/handovers/X/n.md" --dry-run > "$T/out" 2>&1
echo "=== PROBE T7a-shape rc=$? lines=$(wc -l < "$T/out")"
grep -n "headroom-proxy\|dry-run complete\|^ERR\|^WARN" "$T/out" | cut -c1-200 | head -12
tail -25 "$T/out" | cut -c1-200
exit 1
