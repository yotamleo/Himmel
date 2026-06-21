#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../tools/lib/clip-lookup.mjs"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
LIBURL="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$lib")"
# The harvest runbook's thinness decision must come from the shared predicate.
cat > "$tmp/h.mjs" <<'JS'
const { isThinClipBody } = await import(process.env.LIB);
const NL = "\n";
const skel = NL + "## Core Argument" + NL + "*(claim?)*" + NL + "## Key Evidence" + NL + "- ";
if (isThinClipBody(skel,"research")!==true){console.error("FAIL skeleton");process.exit(1);}
const real = NL + "## Summary" + NL + "Real multi-sentence summary of the article body.";
if (isThinClipBody(real,"research")!==false){console.error("FAIL real");process.exit(1);}
console.log("OK harvest thinness decision");
JS
LIB="$LIBURL" node "$tmp/h.mjs"
# Doc-contract: the runbook must instruct partial+thin-body, and must shell out
# to the mechanical is-thin-cli (not "eyeball it").
hc="$here/../commands/harvest-clips.md"
grep -qi "thin-body" "$hc" || { echo "FAIL: harvest-clips missing thin-body rule"; exit 1; }
grep -q "is-thin-cli.mjs" "$hc" || { echo "FAIL: harvest-clips not wired to is-thin-cli shim"; exit 1; }
echo "HARVEST-THINNESS PASS"
