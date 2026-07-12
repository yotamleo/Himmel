#!/usr/bin/env bash
# Invariant tests for /synthesize-clips.
#
# Scope: validates the bash-checkable invariants — input filter, dedup
# window, confidence-floor logic, deterministic slug derivation — without
# invoking the LLM agent itself. The pattern-detection LLM behavior is
# tested during calibration on real clips; these tests pin the structural
# contracts.

set -u -o pipefail

# Note: this test does NOT load fixture files from disk — it generates
# a synthetic 5-clip vault in $TMP via fake_clip() below.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

assert() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"
        pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

# Build a mini-vault: 5 fake processed clips, 1 unprocessed, plus a
# pre-existing synthesis page to test the dedup window.
VAULT="$TMP/vault"
CLIP="$VAULT/Clippings"
SYNTH="$VAULT/Clippings/_synthesis"
mkdir -p "$SYNTH"

# Helper to emit a fake clip.
fake_clip() {
    local name="$1"; local domain="$2"; local author="$3"
    local processed="$4"; local triaged_at="$5"; local promotion="$6"
    local date_clipped="${7:-2026-05-20}"
    local f="$CLIP/$name.md"
    {
        echo "---"
        echo "title: \"$name\""
        echo "author: $author"
        echo "source: https://$domain/$name"
        echo "site: $domain"
        echo "date_clipped: $date_clipped"
        echo "type: article"
        echo "tags:"
        echo "  - article"
        if [ "$processed" = "yes" ]; then
            echo "processed: true"
            echo "triaged_at: $triaged_at"
        fi
        echo "---"
        echo "# $name"
        echo ""
        echo "Body here."
        if [ -n "$promotion" ]; then
            echo ""
            echo "## Promotion candidate"
            echo "- **Suggested target:** \`$promotion\`"
        fi
    } > "$f"
}

# 5 processed clips with overlap on domain medium.com / author Alice.
# Alice's clips spread >24h apart so the cluster genuinely clears the
# 24h-window floor (Test 2b relies on this — HIMMEL-242).
fake_clip "clip-1" "medium.com" "Alice" yes 2026-05-21 "30-Resources/Concepts/" 2026-05-19
fake_clip "clip-2" "medium.com" "Alice" yes 2026-05-22 "30-Resources/Concepts/" 2026-05-20
fake_clip "clip-3" "medium.com" "Alice" yes 2026-05-22 "30-Resources/Concepts/" 2026-05-22
fake_clip "clip-4" "arxiv.org"  "Bob"   yes 2026-05-22 "30-Resources/Tech/"
fake_clip "clip-5" "x.com"      "Carol" yes 2026-05-23 "Ideas/"
# 1 unprocessed clip (should be excluded from synthesis input).
fake_clip "clip-6" "reddit.com" "Dan"   no  -         ""

echo "Test 1: input filter — only processed clips eligible"
# Count clips with processed:true vs without.
eligible=0
ineligible=0
for f in "$CLIP"/*.md; do
    if grep -q "^processed: true$" "$f" 2>/dev/null; then
        eligible=$((eligible+1))
    else
        ineligible=$((ineligible+1))
    fi
done
assert "5 processed clips eligible" "5" "$eligible"
assert "1 unprocessed clip excluded" "1" "$ineligible"

echo "Test 2: confidence-floor — single-source-domain pattern is below floor"
# Count distinct source domains among the 5 processed clips.
distinct_domains=$(for f in "$CLIP"/clip-{1,2,3,4,5}.md; do grep "^site: " "$f" 2>/dev/null; done | sort -u | wc -l | tr -d ' ')
assert "5 processed clips span >1 domain (synthesis would fire)" "3" "$distinct_domains"

# Synthesize a hypothetical Pattern 1 CONCEPT cluster — 3 clips, all
# single-source (medium.com). The confidence floor MUST reject.
# (Domain floor applies to Patterns 1, 3, 4 — NOT Pattern 2; HIMMEL-242.)
single_source_count=0
for f in "$CLIP"/clip-{1,2,3}.md; do
    grep -q "^site: medium.com$" "$f" 2>/dev/null && single_source_count=$((single_source_count+1))
done
if [ "$single_source_count" -ge 3 ]; then
    # All 3 share medium.com — confidence floor says SKIP.
    floor_decision=skip
else
    floor_decision=fire
fi
assert "single-source-domain concept cluster of 3 → confidence floor skips" "skip" "$floor_decision"

echo "Test 2b: confidence-floor — Pattern 2 (author convergence) exempt from domain floor (HIMMEL-242)"
# Same single-source evidence read as an AUTHOR cluster: Alice has 2+
# clips, all medium.com. Pattern 2 is exempt from the shared-domain test
# (the author IS the source; authors are inherently single-platform), so
# the floor must NOT skip on domain — only the <2-clip count floor and
# the 24h window apply.
alice_count=0
for f in "$CLIP"/clip-{1,2,3}.md; do
    grep -q "^author: Alice$" "$f" 2>/dev/null && alice_count=$((alice_count+1))
done
if [ "$alice_count" -ge 2 ]; then
    # Count floor passes; domain floor does NOT apply to Pattern 2.
    author_floor_decision=fire
else
    author_floor_decision=skip
fi
assert "single-domain author cluster of 2+ → Pattern 2 fires (domain-floor exempt)" "fire" "$author_floor_decision"

# Couple the test to the spec: if the exemption is reverted in
# synthesize-clips.md without touching this suite, this assert fails.
SPEC="$(dirname "$0")/../commands/synthesize-clips.md"
if grep -q "NOT Pattern 2 (HIMMEL-242)" "$SPEC" 2>/dev/null; then
    spec_exemption=present
else
    spec_exemption=absent
fi
assert "spec carries the Pattern 2 domain-floor exemption (HIMMEL-242)" "present" "$spec_exemption"

# Negative count-floor case: the exemption removes only the DOMAIN
# guard — the <2-clip count floor still applies to Pattern 2. Bob has
# exactly 1 clip → skip.
bob_count=0
for f in "$CLIP"/*.md; do
    grep -q "^author: Bob$" "$f" 2>/dev/null && bob_count=$((bob_count+1))
done
if [ "$bob_count" -ge 2 ]; then
    bob_floor_decision=fire
else
    bob_floor_decision=skip
fi
assert "author with 1 clip → Pattern 2 count floor still skips" "skip" "$bob_floor_decision"

echo "Test 3: 14-day dedup window — existing synthesis page blocks re-write"
# Pre-create a synthesis page dated 5 days ago for slug "concept-attention".
existing="$SYNTH/2026-05-20-concept-attention.md"
{
    echo "---"
    echo "date: 2026-05-20"
    echo "type: synthesis"
    echo "---"
    echo "# Concept: Attention"
} > "$existing"

# Dedup check: matches by slug, regardless of date.
proposed_slug="concept-attention"
TODAY="2026-05-25"
window_days=14
dedup_hit=no
for f in "$SYNTH"/*.md; do
    [ -f "$f" ] || continue
    # Extract date prefix (YYYY-MM-DD).
    basename=$(basename "$f" .md)
    date_prefix="${basename:0:10}"
    slug="${basename:11}"
    if [ "$slug" = "$proposed_slug" ]; then
        # Date-diff check via Python (portable).
        days=$(python3 -c "from datetime import date; a=date.fromisoformat('$TODAY'); b=date.fromisoformat('$date_prefix'); print((a-b).days)")
        if [ "$days" -le "$window_days" ]; then
            dedup_hit=yes
            break
        fi
    fi
done
assert "5-day-old synthesis page within 14d window → dedup skips" "yes" "$dedup_hit"

echo "Test 4: stale synthesis page (>14d) does NOT block"
# Move the existing page back to 30 days ago.
stale="$SYNTH/2026-04-25-concept-attention.md"
mv "$existing" "$stale"

dedup_hit_stale=no
for f in "$SYNTH"/*.md; do
    [ -f "$f" ] || continue
    basename=$(basename "$f" .md)
    date_prefix="${basename:0:10}"
    slug="${basename:11}"
    if [ "$slug" = "$proposed_slug" ]; then
        days=$(python3 -c "from datetime import date; a=date.fromisoformat('$TODAY'); b=date.fromisoformat('$date_prefix'); print((a-b).days)")
        if [ "$days" -le "$window_days" ]; then
            dedup_hit_stale=yes
            break
        fi
    fi
done
assert "30-day-old synthesis page outside 14d window → dedup does NOT block (supersedes path)" "no" "$dedup_hit_stale"

echo "Test 5: deterministic slug derivation"
# Concept slug: lowercase + hyphenate.
derive_concept_slug() {
    echo "concept-$1" | tr 'A-Z ' 'a-z-' | tr -s '-'
}
s1=$(derive_concept_slug "Attention Residue")
assert "concept slug: Attention Residue → concept-attention-residue" "concept-attention-residue" "$s1"

s2=$(derive_concept_slug "Attention Residue")
assert "concept slug is deterministic across calls" "$s1" "$s2"

# Author slug
derive_author_slug() {
    echo "author-$1" | tr 'A-Z ' 'a-z-' | tr -s '-'
}
sa=$(derive_author_slug "Jane Smith")
assert "author slug: Jane Smith → author-jane-smith" "author-jane-smith" "$sa"

# Tag MOC slug
derive_tag_slug() {
    echo "tag-$1-moc"
}
st=$(derive_tag_slug "focus")
assert "tag slug: focus → tag-focus-moc" "tag-focus-moc" "$st"

echo ""
echo "Results: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
