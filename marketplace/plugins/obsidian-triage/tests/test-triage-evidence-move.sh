#!/usr/bin/env bash
# Functional tests for /triage-clips Phase 8 — move processed clip to
# Clippings/_evidence/ with boundary-safe inbound-link rewrite (LUNA-84).
#
# Mirrors test-archive-clips.sh Tests 10+13 in style: simulates the
# move+rewrite algorithm directly in shell on a hermetic temp vault,
# then asserts end-state rather than invoking the LLM agent.
#
# TDD: these tests were written BEFORE Phase 8 was added to triage-clips.md.
# The shell logic tested here IS the algorithm Phase 8 specifies.

set -u -o pipefail

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

# ── Fixture setup ────────────────────────────────────────────────────────────

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A realistic clip id WITH metachars: en-dash, space, + (all regex metachars)
ID='@karpathy – 2026-05-25T031232+0200'
BASENAME="$ID"                    # flat _evidence/ pool: basename unchanged
OLD="$ID"                         # clip path relative to Clippings/, no .md
NEW="_evidence/$BASENAME"         # dest relative to Clippings/, no .md
SIB="$ID-extra"                   # prefix-sibling — must NOT be touched

mkdir -p "$tmp/Clippings/_evidence"
mkdir -p "$tmp/Clippings/_synthesis"
mkdir -p "$tmp/50-Journal/Daily"
mkdir -p "$tmp/30-Resources/Tech"

# Clip: processed:true with Phase-6 Promotion-candidate self-ref
# (backticked [[Clippings/<id>]] — the LUNA-60 self-ref that must be remapped)
{
    printf -- '---\ntype: research\nharvested_at: 2026-05-25\nprocessed: true\n'
    printf -- 'triaged_at: 2026-05-25\nevidence_kind:\n  - concepts\n  - tools\n---\n'
    printf -- 'body\n\n## Promotion candidate\n'
    # shellcheck disable=SC2016  # backtick is literal markdown text, not command substitution
    printf -- '- **Bi-temporal anchor:** carry `derived_from: [[Clippings/%s]]` and fresh date.\n' "$ID"
} > "$tmp/Clippings/$ID.md"

# Daily note: Phase-5 backref `(from [[Clippings/<id>]])`
{
    printf -- '---\ndate: 2026-05-25\ntype: daily\n---\n\n## Actions from clips\n'
    printf -- '- [ ] do thing (from [[Clippings/%s]])\n' "$ID"
} > "$tmp/50-Journal/Daily/2026-05-25.md"

# External note: two forms (plain + aliased)
{
    printf -- '- see [[Clippings/%s]]\n' "$ID"
    printf -- '- alias [[Clippings/%s|Karpathy Note]]\n' "$ID"
} > "$tmp/30-Resources/Tech/review.md"

# Heading-anchored note: the third boundary form `#` (kept separate so the
# `#` rewrite + verify are NON-vacuous — if the `#` form were dropped from
# the loop/verify, Test 7b and Test 10 would fail).
printf -- '- cite [[Clippings/%s#Key Ideas]]\n' "$ID" > "$tmp/30-Resources/Tech/headed.md"

# Synthesis page citing the clip WITH the `.md` extension — the three `.md`
# boundary forms (`.md]]`, `.md|`, `.md#`). Real _synthesis/ pages cite clips
# with `.md`; a 3-form (no-`.md`) enumerate+verify reports clean while these
# silently dangle after the move. These fixtures make the `.md` coverage
# NON-vacuous: dropping any `.md` form fails Test 1b / 7c / 7d / 7e / 10.
{
    printf -- '- plain md: [[Clippings/%s.md]]\n' "$ID"
    printf -- '- alias md: [[Clippings/%s.md|Karpathy Thread]]\n' "$ID"
    printf -- '- heading md: [[Clippings/%s.md#Key Ideas]]\n' "$ID"
} > "$tmp/Clippings/_synthesis/synth.md"

# Prefix-sibling: must NOT be touched (boundary guard) — plain AND `.md` forms.
{
    printf -- '- link [[Clippings/%s]]\n' "$SIB"
    printf -- '- linkmd [[Clippings/%s.md]]\n' "$SIB"
} > "$tmp/Clippings/$SIB.md"

# ── Pre-move assertions ───────────────────────────────────────────────────────

echo "Test 1: step-3 grep finds all inbound link files (self-ref + daily + external + heading + .md synthesis)"
# SIX forms: ]] | #  +  .md]] .md| .md# — the full boundary set (mirrors the
# migration engine's sixForms) that prevents <OLD>-extra from matching AND
# catches `.md`-suffixed citations.
hits=$(grep -rlF \
    -e "[[Clippings/$OLD]]" \
    -e "[[Clippings/$OLD|" \
    -e "[[Clippings/$OLD#" \
    -e "[[Clippings/$OLD.md]]" \
    -e "[[Clippings/$OLD.md|" \
    -e "[[Clippings/$OLD.md#" \
    "$tmp" --include='*.md' 2>/dev/null | wc -l | tr -d ' ')
# clip (self-ref) + daily note + external review.md + headed.md (# form) + synth.md (.md forms) = 5
assert "step-3 grep finds 5 inbound link files before move (incl .md synthesis)" "5" "$hits"

echo "Test 1b: .md-form synthesis page IS among the step-3 hits (non-vacuous .md enumerate)"
if grep -lF \
    -e "[[Clippings/$OLD.md]]" \
    -e "[[Clippings/$OLD.md|" \
    -e "[[Clippings/$OLD.md#" \
    "$tmp/Clippings/_synthesis/synth.md" >/dev/null 2>&1; then f=found; else f=missed; fi
assert "synthesis .md citation enumerated by six-form grep" "found" "$f"

echo "Test 2: prefix-sibling NOT in step-3 hits (boundary-complete correctness, incl .md)"
hits_sib=$(grep -rlF \
    -e "[[Clippings/$OLD]]" \
    -e "[[Clippings/$OLD|" \
    -e "[[Clippings/$OLD#" \
    -e "[[Clippings/$OLD.md]]" \
    -e "[[Clippings/$OLD.md|" \
    -e "[[Clippings/$OLD.md#" \
    "$tmp/Clippings/$SIB.md" --include='*.md' 2>/dev/null | wc -l | tr -d ' ')
assert "prefix-sibling excluded from step-3 hits (boundary safe, incl .md)" "0" "$hits_sib"

# ── Phase 8 move simulation ───────────────────────────────────────────────────

CLIP_OLD_PATH="$tmp/Clippings/$ID.md"

# Step 3: enumerate inbound BEFORE move (bash 3.2 safe: write to file, not array)
INBOUND_LIST="$tmp/inbound.txt"
grep -rlF \
    -e "[[Clippings/$OLD]]" \
    -e "[[Clippings/$OLD|" \
    -e "[[Clippings/$OLD#" \
    -e "[[Clippings/$OLD.md]]" \
    -e "[[Clippings/$OLD.md|" \
    -e "[[Clippings/$OLD.md#" \
    "$tmp" --include='*.md' 2>/dev/null > "$INBOUND_LIST" || true

# Step 4: move the file
mv "$tmp/Clippings/$OLD.md" "$tmp/Clippings/$NEW.md"

echo "Test 3: clip moved to Clippings/_evidence/<basename>.md"
moved=$([ -f "$tmp/Clippings/$NEW.md" ] && echo yes || echo no)
assert "clip moved to Clippings/_evidence/<basename>.md" "yes" "$moved"

echo "Test 4: clip gone from top-level Clippings/"
gone=$([ ! -f "$tmp/Clippings/$OLD.md" ] && echo yes || echo no)
assert "clip gone from top-level Clippings/" "yes" "$gone"

# Step 5: literal rewrite — bash ${//} is fixed-string, handles + space en-dash
while IFS= read -r f; do
    # self-ref: the clip is now at its NEW path (old inbox path is gone)
    rewrite_at="$f"
    if [ "$f" = "$CLIP_OLD_PATH" ]; then
        rewrite_at="$tmp/Clippings/$NEW.md"
    fi
    [ -f "$rewrite_at" ] || continue
    c="$(cat "$rewrite_at")"
    # SIX literal replacements — plain forms map to the no-`.md` _evidence target;
    # `.md` forms keep the `.md` (and the |alias / #heading tail). The plain `]]`
    # form never matches `.md]]` (boundary char differs), so order is safe.
    c="${c//"[[Clippings/$OLD]]"/"[[Clippings/$NEW]]"}"
    c="${c//"[[Clippings/$OLD|"/"[[Clippings/$NEW|"}"
    c="${c//"[[Clippings/$OLD#"/"[[Clippings/$NEW#"}"
    c="${c//"[[Clippings/$OLD.md]]"/"[[Clippings/$NEW.md]]"}"
    c="${c//"[[Clippings/$OLD.md|"/"[[Clippings/$NEW.md|"}"
    c="${c//"[[Clippings/$OLD.md#"/"[[Clippings/$NEW.md#"}"
    printf '%s\n' "$c" > "$rewrite_at"
done < "$INBOUND_LIST"

# ── Post-move assertions ──────────────────────────────────────────────────────

echo "Test 5: daily backref rewritten to [[Clippings/_evidence/<basename>]]"
daily="$tmp/50-Journal/Daily/2026-05-25.md"
if grep -qF "[[Clippings/$NEW]]" "$daily"; then f=yes; else f=no; fi
assert "daily backref rewritten to [[Clippings/$NEW]]" "yes" "$f"

echo "Test 6: external note plain link rewritten"
ext="$tmp/30-Resources/Tech/review.md"
if grep -qF "[[Clippings/$NEW]]" "$ext"; then f=yes; else f=no; fi
assert "external note plain link rewritten" "yes" "$f"

echo "Test 7: external note alias link rewritten (tail preserved)"
if grep -qF "[[Clippings/$NEW|Karpathy Note]]" "$ext"; then f=yes; else f=no; fi
assert "external note alias tail preserved on rewrite" "yes" "$f"

echo "Test 7b: heading-anchored link rewritten (# form, tail preserved) — non-vacuous # coverage"
headed="$tmp/30-Resources/Tech/headed.md"
if grep -qF "[[Clippings/$NEW#Key Ideas]]" "$headed"; then f=yes; else f=no; fi
assert "external note heading tail preserved on rewrite (# form)" "yes" "$f"

synth="$tmp/Clippings/_synthesis/synth.md"
echo "Test 7c: .md]] synthesis citation rewritten to _evidence/<base>.md]] (suffix preserved)"
if grep -qF "[[Clippings/$NEW.md]]" "$synth"; then f=yes; else f=no; fi
assert ".md]] citation → [[Clippings/$NEW.md]]" "yes" "$f"

echo "Test 7d: .md|alias synthesis citation rewritten (suffix + alias tail preserved)"
if grep -qF "[[Clippings/$NEW.md|Karpathy Thread]]" "$synth"; then f=yes; else f=no; fi
assert ".md|alias citation → [[Clippings/$NEW.md|Karpathy Thread]]" "yes" "$f"

echo "Test 7e: .md#heading synthesis citation rewritten (suffix + heading tail preserved)"
if grep -qF "[[Clippings/$NEW.md#Key Ideas]]" "$synth"; then f=yes; else f=no; fi
assert ".md#heading citation → [[Clippings/$NEW.md#Key Ideas]]" "yes" "$f"

echo "Test 8: moved clip self-ref remapped at new path (LUNA-60)"
dest="$tmp/Clippings/$NEW.md"
if grep -qF "[[Clippings/$NEW]]" "$dest"; then f=remapped; else f=stale; fi
assert "moved clip self-ref remapped to _evidence path" "remapped" "$f"

echo "Test 9: prefix-sibling NOT touched"
if grep -qF "[[Clippings/$SIB]]" "$tmp/Clippings/$SIB.md"; then f=intact; else f=clobbered; fi
assert "prefix-sibling [[Clippings/$SIB]] intact" "intact" "$f"

echo "Test 9b: sibling .md form NOT touched (boundary guard, .md)"
if grep -qF "[[Clippings/$SIB.md]]" "$tmp/Clippings/$SIB.md"; then f=intact; else f=clobbered; fi
assert "prefix-sibling [[Clippings/$SIB.md]] intact" "intact" "$f"

echo "Test 10: boundary-complete verify — zero stale OLD links across vault (SIX forms)"
stale=$(grep -rlF \
    -e "[[Clippings/$OLD]]" \
    -e "[[Clippings/$OLD|" \
    -e "[[Clippings/$OLD#" \
    -e "[[Clippings/$OLD.md]]" \
    -e "[[Clippings/$OLD.md|" \
    -e "[[Clippings/$OLD.md#" \
    "$tmp" --include='*.md' 2>/dev/null | wc -l | tr -d ' ')
assert "zero stale [[Clippings/<OLD>]] (literal six-form boundary-complete verify)" "0" "$stale"

echo "Test 11: triage scan (maxdepth 2, -not -path '*/_evidence/*') excludes moved clip"
triage_scan=$(find "$tmp/Clippings" -maxdepth 2 -type f -name '*.md' \
    -not -path '*/_synthesis/*' -not -path '*/_done/*' -not -name '_deferred.md' \
    -not -path '*/_evidence/*' 2>/dev/null)
if printf '%s\n' "$triage_scan" | grep -qF "/$ID.md"; then f=leaked; else f=excluded; fi
assert "triage scan excludes moved clip" "excluded" "$f"

echo "Test 12: archive eligibility scan (maxdepth 3) also excludes moved clip"
archive_scan=$(find "$tmp/Clippings" -maxdepth 3 -type f -name '*.md' \
    -not -path '*/_synthesis/*' -not -path '*/_done/*' -not -name '_deferred.md' \
    -not -path '*/_evidence/*' 2>/dev/null)
if printf '%s\n' "$archive_scan" | grep -qF "/$ID.md"; then f=leaked; else f=excluded; fi
assert "archive scan excludes moved clip (_evidence/ excluded)" "excluded" "$f"

echo "Test 13: sibling remains visible in scans (not accidentally excluded)"
if printf '%s\n' "$triage_scan" | grep -qF "/$SIB.md"; then f=visible; else f=missing; fi
assert "prefix-sibling still visible in triage scan" "visible" "$f"

# HIMMEL-770: ig_media_pending step-0 hold -- a two-clip behavioral mirror of the
# runbook contract. Both clips are Phase-7-complete (processed: true) and would
# otherwise be moved to _evidence/; they run through the SAME move logic as the
# main sim above, gated by the runbook's Phase-8 step-0 eligibility filter:
#   0. If frontmatter has `ig_media_pending: true`, SKIP the move (stays in
#      Clippings/ until /ig-media-enrich clears the flag).
# Non-vacuous: BOTH clips are actually run through the move; the step-0 filter is
# what keeps the pending one in the inbox while the plain one lands in _evidence/.
PLAIN='plain-processed-clip'
PEND='pending-ig-clip'
printf -- '---\ntype: article\nprocessed: true\ntriaged_at: 2026-07-08\n---\nplain body\n' \
    > "$tmp/Clippings/$PLAIN.md"
printf -- '---\ntype: article\nprocessed: true\ntriaged_at: 2026-07-08\nig_media_pending: true\n---\npending body\n' \
    > "$tmp/Clippings/$PEND.md"

# Run each through the move sim with the step-0 filter.
for base in "$PLAIN" "$PEND"; do
    src="$tmp/Clippings/$base.md"
    # Step 0: the eligibility check the runbook specifies -- held clips are
    # skipped BEFORE the move; every other Phase-7-complete clip moves.
    if grep -qE '^ig_media_pending:[[:space:]]*true' "$src"; then
        continue
    fi
    mv "$src" "$tmp/Clippings/_evidence/$base.md"
done

echo "Test 14: step-0 filter -- plain processed clip lands in _evidence/"
moved_plain=$([ -f "$tmp/Clippings/_evidence/$PLAIN.md" ] && [ ! -f "$tmp/Clippings/$PLAIN.md" ] && echo yes || echo no)
assert "plain processed clip moved to _evidence/ (not held)" "yes" "$moved_plain"

echo "Test 15: step-0 filter -- ig_media_pending clip stays in Clippings/ (held)"
held_pend=$([ -f "$tmp/Clippings/$PEND.md" ] && [ ! -f "$tmp/Clippings/_evidence/$PEND.md" ] && echo yes || echo no)
assert "ig_media_pending clip stays in inbox (Phase-8 step-0 hold)" "yes" "$held_pend"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && exit 1 || exit 0
