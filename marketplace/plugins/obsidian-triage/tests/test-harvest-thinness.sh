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

# HIMMEL-3043: thin instagram clips must get ig_media_pending: true (idempotent)
# so /ig-media-enrich picks them up; other instagram wiring lives in
# harvest-clip-body-batch.py's process_clip -> persist_thin_partial.
tool="$here/../tools/harvest-clip-body-batch.py"
cat > "$tmp/ig_pending.py" <<PY
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("harvest_batch", "$tool")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.TODAY = "2026-09-14"

p = Path("$tmp/ig-thin.md")
p.write_text(
    "---\ntype: instagram\nsource: https://www.instagram.com/reel/IGTH043/\n---\nshort.\n",
    encoding="utf-8",
)
glyph, msg, _ = mod.process_clip(p, dry_run=False, firecrawl=None)
first = p.read_text(encoding="utf-8")
if glyph != "~" or "ig_media_pending: true" not in first:
    print("FAIL: thin instagram clip did not get ig_media_pending: true")
    print(first)
    sys.exit(1)

glyph2, msg2, _ = mod.process_clip(p, dry_run=False, firecrawl=None)
second = p.read_text(encoding="utf-8")
if second.count("ig_media_pending:") != 1:
    print("FAIL: second run duplicated ig_media_pending (not idempotent)")
    print(second)
    sys.exit(1)
if "ig_media_pending: true" not in second:
    print("FAIL: second run lost ig_media_pending: true")
    print(second)
    sys.exit(1)

# non-instagram thin clip must NOT get the key at all.
p2 = Path("$tmp/generic-thin.md")
p2.write_text(
    "---\ntype: article\nsource: https://example.com/post\n---\nshort.\n",
    encoding="utf-8",
)
mod.process_clip(p2, dry_run=False, firecrawl=None)
if "ig_media_pending" in p2.read_text(encoding="utf-8"):
    print("FAIL: non-instagram thin clip got ig_media_pending")
    sys.exit(1)

print("OK ig_media_pending thin-IG + idempotence + non-IG exclusion")
PY
python3 "$tmp/ig_pending.py"

# HIMMEL-3043: the clip scan must skip _evidence/ (the reviewed-evidence pool)
# the same way it already skips _synthesis/, _done/ and _deferred.md.
VEV="$tmp/vault-evidence"
mkdir -p "$VEV/Clippings/_evidence"
cat > "$VEV/Clippings/_evidence/leaked.md" <<'EOF'
---
type: instagram
source: https://www.instagram.com/reel/EVID043/
---
short.
EOF
before_evidence="$(cat "$VEV/Clippings/_evidence/leaked.md")"
python3 "$here/../tools/harvest-clip-body-batch.py" "$VEV" >"$tmp/evidence.out" 2>&1
after_evidence="$(cat "$VEV/Clippings/_evidence/leaked.md")"
if [ "$before_evidence" != "$after_evidence" ]; then
    echo "FAIL: _evidence/ clip was modified by the clip scan"
    diff <(echo "$before_evidence") <(echo "$after_evidence") || true
    exit 1
fi
if grep -q "EVID043" "$tmp/evidence.out"; then
    echo "FAIL: _evidence/ clip was reported as scanned"
    cat "$tmp/evidence.out"
    exit 1
fi
echo "OK _evidence/ clip untouched by clip scan"

echo "HARVEST-THINNESS PASS"
