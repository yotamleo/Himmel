#!/usr/bin/env bash
# Fixture-gated acceptance test for existing-subject fuzzy-match + densify
# (LUNA-88). Before LUNA-87 creates a stub, an alias-scan of existing
# 30-Resources/{Concepts,Tech} + 60-Maps/*-MOC must densify a matching subject
# instead of creating a duplicate.
#
# Contract (handover HARD GUARDRAIL #3): given fixture F + an existing C-MOC,
# the run densifies C-MOC (evidence appended) and creates 0 new pages for C;
# a genuinely-new concept still stubs. Synonyms matched via declared `aliases:`.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$PLUGIN_DIR/tools/synthesize-stubs.mjs"

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
EV="$tmp/Clippings/_evidence"
mkdir -p "$EV" "$tmp/30-Resources/Concepts" "$tmp/30-Resources/Tech" "$tmp/60-Maps"

mkclip() { # $1=file $2=author $3=url $4=tag
  cat > "$EV/$1" <<EOF
---
type: article
source: "$3"
author: $2
processed: true
evidence_kind:
  - concepts
tags:
  - $4
---
clip $1
EOF
}

# Concept C — has an existing MOC (fuzzy/normalized name match).
mkclip cw1.md "Alice R" "https://example.com/cw"  "context-windows"
mkclip cw2.md "Bob W"   "https://other.org/cw2"   "context-windows"
# Synonym case — tag `self-hosted`, existing page is `Local-First` w/ alias.
mkclip sh1.md "Carol H" "https://carol.com/sh"    "self-hosted"
mkclip sh2.md "Dave K"  "https://dave.org/sh2"    "self-hosted"
# Genuinely-new concept — no existing subject → must still stub.
mkclip vd1.md "Erin V"  "https://erin.com/vd"     "vector-databases"
mkclip vd2.md "Frank D" "https://frank.org/vd2"   "vector-databases"

# Existing subjects.
MOC="$tmp/60-Maps/Context-Windows-MOC.md"
cat > "$MOC" <<'EOF'
---
type: moc
tags:
  - moc
---
# Context Windows MOC

## Evidence

- (existing hand-written note)
EOF

LOCALFIRST="$tmp/30-Resources/Concepts/Local-First.md"
cat > "$LOCALFIRST" <<'EOF'
---
type: concept
aliases:
  - self-hosted
  - selfhosting
tags:
  - concept
---
# Local First

## Definition

Own your data.
EOF

LEDGER="$tmp/.synthesize-stubs.ledger.jsonl"

echo "Test group 1: apply (fuzzy-match densify + new stub)"
out1="$(node "$TOOL" "$tmp" --apply 2>&1)"
printf '%s\n' "$out1"

# C-MOC densified, NOT duplicated.
if grep -qF '[[Clippings/_evidence/cw1]]' "$MOC" && grep -qF '[[Clippings/_evidence/cw2]]' "$MOC"; then f=yes; else f=no; fi
assert "existing C-MOC densified (evidence appended)" "yes" "$f"

if [ -f "$tmp/30-Resources/Concepts/Context Windows.md" ]; then f=dup; else f=none; fi
assert "no duplicate Concepts page for C (0 new)" "none" "$f"

# Synonym via alias densified, not duplicated.
if grep -qF '[[Clippings/_evidence/sh1]]' "$LOCALFIRST"; then f=yes; else f=no; fi
assert "alias synonym (self-hosted -> Local-First) densified" "yes" "$f"

if [ -f "$tmp/30-Resources/Concepts/Self Hosted.md" ]; then f=dup; else f=none; fi
assert "no duplicate page for the synonym (0 new)" "none" "$f"

# Genuinely-new concept still stubs.
if [ -f "$tmp/30-Resources/Concepts/Vector Databases.md" ]; then f=yes; else f=no; fi
assert "genuinely-new concept still stubs" "yes" "$f"

# Contributors stamped toward the densified subject.
if grep -qF 'promoted_to:' "$EV/cw1.md" && grep -qF 'promoted_to:' "$EV/sh1.md"; then f=yes; else f=no; fi
assert "densify contributors stamped promoted_to" "yes" "$f"

# Ledger carries densify entries.
if grep -qF '"action":"densify"' "$LEDGER" 2>/dev/null; then f=yes; else f=no; fi
assert "ledger records densify action" "yes" "$f"

echo "Test group 2: revert untouched (densify undone)"
node "$TOOL" "$tmp" --revert "$LEDGER" >/dev/null 2>&1
if grep -qF '[[Clippings/_evidence/cw1]]' "$MOC"; then f=present; else f=removed; fi
assert "densify reverted (appended evidence removed from MOC)" "removed" "$f"

if grep -qF '(existing hand-written note)' "$MOC"; then f=yes; else f=no; fi
assert "pre-existing MOC content preserved after revert" "yes" "$f"

if grep -qF 'promoted_to:' "$EV/cw1.md"; then f=stamped; else f=cleared; fi
assert "promoted_to cleared on densify revert" "cleared" "$f"

if [ -f "$tmp/30-Resources/Concepts/Vector Databases.md" ]; then f=present; else f=removed; fi
assert "new stub also reverted (page removed)" "removed" "$f"

echo "Test group 3: revert touched densify (divergence refusal)"
node "$TOOL" "$tmp" --apply >/dev/null 2>&1
printf '\n- operator edit\n' >> "$MOC"
out3="$(node "$TOOL" "$tmp" --revert "$LEDGER" 2>&1)"
printf '%s\n' "$out3"
if grep -qF '[[Clippings/_evidence/cw1]]' "$MOC"; then f=present; else f=removed; fi
assert "touched MOC densify NOT reverted (divergence guard)" "present" "$f"

echo ""
echo "test-synthesize-densify: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
