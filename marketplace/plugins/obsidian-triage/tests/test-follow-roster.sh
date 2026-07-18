#!/usr/bin/env bash
# Tests for HIMMEL-660 follow-roster.mjs — handle normalization + roster
# resolution (list ∪ corpus, minClips threshold). Filesystem-only; no
# network. Cross-platform: bash on Linux/macOS/Git-Bash. Uses node (not
# bun) for CI.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
LIB="$TOOLS_DIR/lib/follow-roster.mjs"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1))
    fi
}

# -- Test 1: normalizeHandle -------------------------------------------------
echo "Test 1: normalizeHandle"
lib_url_early="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$LIB")"
out="$(node -e '
import(process.argv[1]).then(m => {
  const cases = [["@Theo","theo"],["https://x.com/_avichawla","_avichawla"],
                 ["twitter.com/bcherny/","bcherny"],["CyrilXBT","cyrilxbt"]];
  let ok=1; for (const [i,e] of cases) if (m.normalizeHandle(i)!==e){ok=0;console.log("MISS",i,m.normalizeHandle(i))}
  console.log(ok?"NORM_OK":"NORM_FAIL");
});' "$lib_url_early" 2>&1)"
echo "$out" | grep -q "NORM_OK" && r=yes || r=no
assert "normalizeHandle: all cases match" yes "$r"

# -- Test 2: resolveRoster ----------------------------------------------------
echo "Test 2: resolveRoster"

# fixture vault: 2 clips author:["@_avichawla"], 1 clip tweet_author: theo
vault="$tmpdir/vault"
mkdir -p "$vault/.obsidian"
mkdir -p "$vault/Clippings"

cat > "$vault/Clippings/clip-avichawla-1.md" <<'EOF'
---
title: "clip 1"
author:
  - "@_avichawla"
source: "https://x.com/_avichawla/status/1"
type: tweet
---
## The Idea
Real captured tweet text here, definitely not a placeholder.
EOF

cat > "$vault/Clippings/clip-avichawla-2.md" <<'EOF'
---
title: "clip 2"
author:
  - "@_avichawla"
source: "https://x.com/_avichawla/status/2"
type: tweet
---
## The Idea
Real captured tweet text here, definitely not a placeholder.
EOF

cat > "$vault/Clippings/clip-theo.md" <<'EOF'
---
title: "clip 3"
tweet_author: theo
source: "https://x.com/theo/status/3"
type: tweet
---
## The Idea
Real captured tweet text here, definitely not a placeholder.
EOF

# stub list file: @bcherny only
listfile="$tmpdir/list.md"
cat > "$listfile" <<'EOF'
# AI on X — curated follow-list

## Tier 1
- **[@bcherny](https://x.com/bcherny)** (5) — Claude Code (Anthropic); direct harness relevance.
EOF

node --check "$LIB" 2>/dev/null && s=ok || s=fail
assert "follow-roster.mjs parses" ok "$s"

lib_url="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$LIB")"

# minClips=2: theo (1 clip) excluded; _avichawla (2, not in list) included;
# bcherny (0, in list) included.
# NB: vault/listfile paths go through env vars (not embedded literally in
# the .mjs source) — MSYS/Git-Bash auto-converts POSIX paths in argv/env
# when invoking a native Windows node.exe, but NOT plain text written into
# a heredoc-generated file, so a literal path baked into source would be
# unresolvable on Windows.
cat > "$tmpdir/roster-min2.mjs" <<EOF
import { resolveRoster } from "$lib_url";
const r = resolveRoster(process.env.FR_VAULT, process.env.FR_LISTFILE, { minClips: 2 });
const byHandle = Object.fromEntries(r.map(e => [e.handle, e]));
console.log("HANDLES=" + r.map(e => e.handle).sort().join(","));
console.log("AVICHAWLA_COUNT=" + (byHandle["_avichawla"] ? byHandle["_avichawla"].clipCount : "MISSING"));
console.log("AVICHAWLA_INLIST=" + (byHandle["_avichawla"] ? byHandle["_avichawla"].inList : "MISSING"));
console.log("BCHERNY_COUNT=" + (byHandle["bcherny"] ? byHandle["bcherny"].clipCount : "MISSING"));
console.log("BCHERNY_INLIST=" + (byHandle["bcherny"] ? byHandle["bcherny"].inList : "MISSING"));
console.log("THEO_PRESENT=" + (byHandle["theo"] ? "yes" : "no"));
EOF
out2="$(FR_VAULT="$vault" FR_LISTFILE="$listfile" node "$tmpdir/roster-min2.mjs" 2>&1)"
echo "$out2" | grep -q 'AVICHAWLA_COUNT=2' && r=yes || r=no; assert "minClips=2: _avichawla clipCount=2" yes "$r"
echo "$out2" | grep -q 'AVICHAWLA_INLIST=false' && r=yes || r=no; assert "minClips=2: _avichawla inList=false" yes "$r"
echo "$out2" | grep -q 'BCHERNY_COUNT=0' && r=yes || r=no; assert "minClips=2: bcherny clipCount=0" yes "$r"
echo "$out2" | grep -q 'BCHERNY_INLIST=true' && r=yes || r=no; assert "minClips=2: bcherny inList=true" yes "$r"
echo "$out2" | grep -q 'THEO_PRESENT=no' && r=yes || r=no; assert "minClips=2: theo excluded (1 clip < minClips)" yes "$r"

# minClips=1: theo (1 clip, not in list) now included.
cat > "$tmpdir/roster-min1.mjs" <<EOF
import { resolveRoster } from "$lib_url";
const r = resolveRoster(process.env.FR_VAULT, process.env.FR_LISTFILE, { minClips: 1 });
const byHandle = Object.fromEntries(r.map(e => [e.handle, e]));
console.log("THEO_COUNT=" + (byHandle["theo"] ? byHandle["theo"].clipCount : "MISSING"));
console.log("THEO_INLIST=" + (byHandle["theo"] ? byHandle["theo"].inList : "MISSING"));
EOF
out1="$(FR_VAULT="$vault" FR_LISTFILE="$listfile" node "$tmpdir/roster-min1.mjs" 2>&1)"
echo "$out1" | grep -q 'THEO_COUNT=1' && r=yes || r=no; assert "minClips=1: theo clipCount=1" yes "$r"
echo "$out1" | grep -q 'THEO_INLIST=false' && r=yes || r=no; assert "minClips=1: theo inList=false" yes "$r"

# -- Results summary -----------------------------------------------------
total=$((pass + fail))
echo ""
echo "Results: $pass / $total passed, $fail failed."
[ "$fail" -eq 0 ]
