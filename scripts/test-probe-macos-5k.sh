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
    --time 23:41 --handover "$T/ho/handovers/X/n.md" --dry-run > "$T/out" 2>&1
echo "rc=$? lines=$(wc -l < "$T/out")"
tail -45 "$T/out" | cut -c1-220
echo "=== PROBE bank-preflight SUT"
mkdir -p "$T/b" "$T/b/home"
export HOME="$T/b/home"
printf '%s' '{"oauthAccount":{"accountUuid":"u"}}' > "$HOME/.claude.json"
# shellcheck disable=SC1091
. "$R/scripts/lib/usage-cache-identity.sh"
A=$(current_account_hash)
printf '{"account":"%s","five_hour":{"utilization":10},"seven_day":{"utilization":20},"primaries_refreshed_at":%s}' "$A" "$(date +%s)" > "$T/b/c.json"
printf '#!/bin/sh\nexit 0\n' > "$T/b/nofleet.sh"; chmod +x "$T/b/nofleet.sh"
CADENCE_BANK_CACHE="$T/b/c.json" CADENCE_BANK_SKIP_REFRESH=1 CADENCE_BANK_LEDGER="$T/b/l.jsonl" \
    CADENCE_BANK_LEG=t FLEET_PS_CMD="$T/b/nofleet.sh" \
    bash -x scripts/lib/bank-preflight.sh </dev/null > "$T/b/out" 2>&1
echo "rc=$?"
tail -50 "$T/b/out" | cut -c1-220
exit 1
