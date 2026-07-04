#!/usr/bin/env bash
# Tests for HIMMEL-660 follow-score.mjs — Task 7 deterministic scoring/
# tiering math (composite/adjusted/tierOf) + rankAccounts overrides. Pure;
# no filesystem/network. Cross-platform: bash on Linux/macOS/Git-Bash.
# Uses node (not bun) for CI.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
LIB="$TOOLS_DIR/lib/follow-score.mjs"

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

node --check "$LIB" 2>/dev/null && s=ok || s=fail
assert "follow-score.mjs parses" ok "$s"

# -- Test 0: crypto-neutrality (M2(a) code-level check) ----------------------
echo "Test 0: crypto-neutrality"

grep -qi "crypto" "$LIB" && r=yes || r=no
assert "follow-score.mjs source contains no 'crypto' token" no "$r"

# NB: fixture paths go through env vars (not embedded literally in a
# heredoc-generated file) -- MSYS/Git-Bash path-mangling trap.
lib_url="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$LIB")"

# -- Test 1: composite/adjusted/tierOf pinned math ---------------------------
echo "Test 1: composite/adjusted/tierOf"

cat > "$tmpdir/math.mjs" <<EOF
import { composite, adjusted, tierOf } from "$lib_url";
const c = composite({ factual_reliability: 4, resources: 4, focus_fit: 4, substance: 4, reach: 4 });
console.log("COMPOSITE_ALL4=" + c);
console.log("ADJUSTED_4_LOW=" + adjusted(4, "low"));
console.log("TIER_3_8=" + tierOf(3.8));
console.log("TIER_2_8=" + tierOf(2.8));
console.log("TIER_1_8=" + tierOf(1.8));
console.log("TIER_1_79=" + tierOf(1.79));
EOF
out1="$(node "$tmpdir/math.mjs" 2>&1)"
echo "$out1" | grep -q '^COMPOSITE_ALL4=4$' && r=yes || r=no; assert "composite(all 4s) === 4" yes "$r"
echo "$out1" | grep -q '^ADJUSTED_4_LOW=2.8' && r=yes || r=no; assert "adjusted(4,\"low\") === 2.8" yes "$r"
echo "$out1" | grep -q '^TIER_3_8=1$' && r=yes || r=no; assert "tierOf(3.8) === 1" yes "$r"
echo "$out1" | grep -q '^TIER_2_8=2$' && r=yes || r=no; assert "tierOf(2.8) === 2" yes "$r"
echo "$out1" | grep -q '^TIER_1_8=3$' && r=yes || r=no; assert "tierOf(1.8) === 3" yes "$r"
echo "$out1" | grep -q '^TIER_1_79=exclude$' && r=yes || r=no; assert "tierOf(1.79) === \"exclude\"" yes "$r"

# -- Test 2: rankAccounts overrides -------------------------------------------
echo "Test 2: rankAccounts overrides"

cat > "$tmpdir/rank.mjs" <<EOF
import { rankAccounts } from "$lib_url";

// handle "a" computes tier "exclude" (adjusted well under 1.8).
const judgmentA = {
  handle: "a",
  scores: { factual_reliability: 1, resources: 1, focus_fit: 1, substance: 1, reach: 1 },
  confidence: "low",
  rationale: "weak account",
  grounding_notes: "n/a",
};

// handle "b" computes Tier 1 (all 5s, high confidence).
const judgmentB = {
  handle: "b",
  scores: { factual_reliability: 5, resources: 5, focus_fit: 5, substance: 5, reach: 5 },
  confidence: "high",
  rationale: "strong account",
  grounding_notes: "n/a",
};

// -- whitelist case: "a" computes exclude, whitelisted -> present at Tier 3 with an override note.
const rankedWhitelist = rankAccounts([judgmentA], { whitelist: ["a"], exclude: [] });
const aEntry = rankedWhitelist.find(e => e.handle === "a");
console.log("WL_PRESENT=" + !!aEntry);
console.log("WL_TIER=" + (aEntry && aEntry.tier));
console.log("WL_HAS_NOTE=" + (aEntry && typeof aEntry.overrideNote === "string" && aEntry.overrideNote.length > 0));

// -- force-exclude case: "b" computes Tier 1, force-excluded -> absent entirely.
const rankedExclude = rankAccounts([judgmentB], { whitelist: [], exclude: ["b"] });
console.log("EXCL_ABSENT=" + (rankedExclude.find(e => e.handle === "b") === undefined));
console.log("EXCL_LENGTH=" + rankedExclude.length);

// -- no override case: "a" alone, not whitelisted -> present, tier exclude, no note.
const rankedPlain = rankAccounts([judgmentA], { whitelist: [], exclude: [] });
const aPlain = rankedPlain.find(e => e.handle === "a");
console.log("PLAIN_TIER=" + (aPlain && aPlain.tier));
console.log("PLAIN_NOTE=" + (aPlain && aPlain.overrideNote));

// -- deterministic tie-break: two accounts landing in the same tier with
// equal adjusted score, differing only on factual_reliability -> higher
// factual_reliability sorts first.
const judgmentC = {
  handle: "c",
  scores: { factual_reliability: 5, resources: 3, focus_fit: 3, substance: 3, reach: 3 },
  confidence: "high",
  rationale: "c",
  grounding_notes: "n/a",
};
const judgmentD = {
  handle: "d",
  scores: { factual_reliability: 3, resources: 5, focus_fit: 3, substance: 3, reach: 3 },
  confidence: "high",
  rationale: "d",
  grounding_notes: "n/a",
};
const rankedTie = rankAccounts([judgmentD, judgmentC], { whitelist: [], exclude: [] });
console.log("TIE_ORDER=" + rankedTie.map(e => e.handle).join(","));
EOF
out2="$(node "$tmpdir/rank.mjs" 2>&1)"
echo "$out2" | grep -q '^WL_PRESENT=true$' && r=yes || r=no; assert "whitelisted exclude-tier handle is present" yes "$r"
echo "$out2" | grep -q '^WL_TIER=3$' && r=yes || r=no; assert "whitelisted exclude-tier handle lands at Tier 3 (no promotion beyond)" yes "$r"
echo "$out2" | grep -q '^WL_HAS_NOTE=true$' && r=yes || r=no; assert "whitelisted override carries a note" yes "$r"
echo "$out2" | grep -q '^EXCL_ABSENT=true$' && r=yes || r=no; assert "force-excluded Tier-1-computing handle is absent" yes "$r"
echo "$out2" | grep -q '^EXCL_LENGTH=0$' && r=yes || r=no; assert "force-excluded handle removed from ranked entirely (length 0)" yes "$r"
echo "$out2" | grep -q '^PLAIN_TIER=exclude$' && r=yes || r=no; assert "non-whitelisted exclude-tier handle stays tier=exclude" yes "$r"
echo "$out2" | grep -q '^PLAIN_NOTE=null$' && r=yes || r=no; assert "non-overridden handle carries no override note" yes "$r"
echo "$out2" | grep -q '^TIE_ORDER=c,d$' && r=yes || r=no; assert "tie-break: equal adjusted -> higher factual_reliability sorts first" yes "$r"

# -- Test 3: renderScorecard grounding-invariant WARNING ---------------------
# Spec invariant: every visible (Tier 1/2/3) entry must cite >=1 verified
# claim OR carry confidence:low. renderScorecard must WARN (stderr, non-fatal)
# when a visible entry violates it, and stay silent when it doesn't.
echo "Test 3: renderScorecard grounding-invariant warning"

cat > "$tmpdir/warn.mjs" <<EOF
import { renderScorecard } from "$lib_url";

// violator: Tier 1, confidence "med", 0 verified claims -> WARN expected.
const violator = {
  handle: "violator",
  scores: { factual_reliability: 4, resources: 4, focus_fit: 4, substance: 4, reach: 4 },
  confidence: "med",
  rationale: "ungrounded",
  grounding_notes: "n/a",
  composite: 4,
  adjusted: 3.4,
  tier: 1,
  overrideNote: null,
};

// compliant: Tier 1, confidence "med", 1 verified claim -> no WARN.
const compliant = {
  handle: "compliant",
  scores: { factual_reliability: 4, resources: 4, focus_fit: 4, substance: 4, reach: 4 },
  confidence: "med",
  rationale: "grounded",
  grounding_notes: "n/a",
  composite: 4,
  adjusted: 3.4,
  tier: 1,
  overrideNote: null,
};

const dossiers = {
  violator: { handle: "violator", claims: [] },
  compliant: {
    handle: "compliant",
    claims: [{ text: "github.com/compliant/repo", kind: "repo", status: "verified" }],
  },
};

renderScorecard([violator, compliant], dossiers);
EOF
out3="$(node "$tmpdir/warn.mjs" 2>&1 1>/dev/null)"
echo "$out3" | grep -q 'WARN.*violator' && r=yes || r=no; assert "WARN fires for ungrounded visible entry" yes "$r"
echo "$out3" | grep -q 'WARN.*compliant' && r=yes || r=no; assert "WARN does NOT fire for grounded entry" no "$r"

# -- Results summary -----------------------------------------------------
total=$((pass + fail))
echo ""
echo "Results: $pass / $total passed, $fail failed."
[ "$fail" -eq 0 ]
