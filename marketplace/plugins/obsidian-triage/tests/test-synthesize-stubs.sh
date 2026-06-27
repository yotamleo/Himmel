#!/usr/bin/env bash
# Fixture-gated acceptance test for SYNTHESIZE stub mode (LUNA-87) — core +
# dedup gate + generation-ledger + divergence guard.
#
# Contract (handover HARD GUARDRAIL #2): fire a stub only when >=2 _evidence/
# clips share a concept/tag/author AFTER (a) canonical-URL dedup of
# contributors AND (b) >=2 distinct domains/authors.
#
# Fixture F:
#   - 2 same-URL dups of one URL (share tag rag-caching)  -> 0 stubs
#   - 2 distinct-author clips on concept C (tag context-windows) -> exactly 1 stub
#
# Asserts: promoted_to: stamped on both contributors; ledger entry written;
# divergence guard refuses to revert a touched page but reverts an untouched one.

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
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

# ── Build a temp vault with fixture F ────────────────────────────────────────
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
EV="$tmp/Clippings/_evidence"
mkdir -p "$EV/_rejected" "$tmp/30-Resources/Concepts" "$tmp/_Templates"

# Concept-C pair: 2 distinct authors, 2 distinct domains, tag context-windows.
cat > "$EV/alice-cw.md" <<'EOF'
---
type: article
source: "https://example.com/cw"
author: Alice Researcher
processed: true
evidence_kind:
  - concepts
tags:
  - context-windows
  - concepts
---
Alice on context windows.
EOF

cat > "$EV/bob-cw.md" <<'EOF'
---
type: article
source: "https://blog.example.org/cw2"
author: Bob Writer
processed: true
evidence_kind:
  - concepts
tags:
  - context-windows
  - concepts
---
Bob on context windows.
EOF

# Same-URL dup pair: same canonical URL after dropping ?source=, tag rag-caching.
cat > "$EV/dup-a.md" <<'EOF'
---
type: article
source: "https://medium.com/rag?source=feed"
author: Carol Author
processed: true
evidence_kind:
  - concepts
tags:
  - rag-caching
  - concepts
---
RAG caching, clipped once.
EOF

cat > "$EV/dup-b.md" <<'EOF'
---
type: article
source: "https://medium.com/rag"
author: Carol Author
processed: true
evidence_kind:
  - concepts
tags:
  - rag-caching
  - concepts
---
RAG caching, clipped twice (same article).
EOF

# A rejected clip that ALSO carries context-windows — must be excluded entirely.
cat > "$EV/_rejected/junk-cw.md" <<'EOF'
---
type: article
source: "https://spam.example.net/x"
author: Spammer
processed: true
tags:
  - context-windows
---
Rejected — must not count toward the gate.
EOF

LEDGER="$tmp/.synthesize-stubs.ledger.jsonl"

# ── 1. APPLY — create stubs ──────────────────────────────────────────────────
echo "Test group 1: apply"
out1="$(node "$TOOL" "$tmp" --apply 2>&1)"
printf '%s
' "$out1"

stub="$tmp/30-Resources/Concepts/Context Windows.md"

if [ -f "$stub" ]; then f=yes; else f=no; fi
assert "context-windows stub created" "yes" "$f"

# Count stub pages under Concepts (must be exactly 1 — dups produce none)
nstubs="$(find "$tmp/30-Resources/Concepts" -type f -name '*.md' | wc -l | tr -d ' ')"
assert "exactly 1 stub page created (dups produce 0)" "1" "$nstubs"

if grep -qF 'status: stub' "$stub" 2>/dev/null; then f=yes; else f=no; fi
assert "stub page has status: stub" "yes" "$f"

# Evidence section wikilinks both contributors
if grep -qF '[[Clippings/_evidence/alice-cw]]' "$stub" && grep -qF '[[Clippings/_evidence/bob-cw]]' "$stub"; then f=yes; else f=no; fi
assert "stub Evidence wikilinks both contributors" "yes" "$f"

# promoted_to stamped on both contributors
if grep -qF 'promoted_to:' "$EV/alice-cw.md" && grep -qF 'promoted_to:' "$EV/bob-cw.md"; then f=yes; else f=no; fi
assert "promoted_to stamped on both contributors" "yes" "$f"

# dup contributors NOT stamped (no stub fired for them)
if grep -qF 'promoted_to:' "$EV/dup-a.md"; then f=stamped; else f=clean; fi
assert "dup clip NOT stamped (collapsed to 1, no stub)" "clean" "$f"

# ledger written with an entry for the stub
if [ -f "$LEDGER" ] && grep -qF 'Context Windows' "$LEDGER"; then f=yes; else f=no; fi
assert "generation-ledger written with stub entry" "yes" "$f"

if grep -qF 'subject_sha256' "$LEDGER" 2>/dev/null; then f=yes; else f=no; fi
assert "ledger entry records subject_sha256 (divergence baseline)" "yes" "$f"

# Re-run apply is idempotent: no second stub, no duplicate ledger create-entry
node "$TOOL" "$tmp" --apply >/dev/null 2>&1
nstubs2="$(find "$tmp/30-Resources/Concepts" -type f -name '*.md' | wc -l | tr -d ' ')"
assert "re-apply is idempotent (still 1 stub)" "1" "$nstubs2"

# ── 2. REVERT divergence guard — UNTOUCHED page is reverted ───────────────────
echo "Test group 2: revert untouched"
out2="$(node "$TOOL" "$tmp" --revert "$LEDGER" 2>&1)"
printf '%s
' "$out2"

if [ -f "$stub" ]; then f=present; else f=removed; fi
assert "untouched stub IS reverted (page removed)" "removed" "$f"

if grep -qF 'promoted_to:' "$EV/alice-cw.md"; then f=stamped; else f=cleared; fi
assert "promoted_to cleared on contributor after revert" "cleared" "$f"

# ── 3. REVERT divergence guard — TOUCHED page is refused ──────────────────────
echo "Test group 3: revert touched (divergence refusal)"
# Re-create the stub
node "$TOOL" "$tmp" --apply >/dev/null 2>&1
[ -f "$stub" ] || { echo "  FAIL  re-create stub for divergence test"; fail=$((fail+1)); }
# Operator edits the page
printf '\n## Operator note\nHand-edited.\n' >> "$stub"

out3="$(node "$TOOL" "$tmp" --revert "$LEDGER" 2>&1)"
printf '%s
' "$out3"

if [ -f "$stub" ]; then f=present; else f=removed; fi
assert "TOUCHED stub is NOT reverted (divergence guard refuses)" "present" "$f"

if echo "$out3" | grep -qiE 'diverg|refus|skip'; then f=yes; else f=no; fi
assert "revert reports divergence refusal" "yes" "$f"

# ── 4. Subject-name collision: two distinct tags title-case to one page ───────
# Distinct tags `local-first` and `local first` both resolve to "Local First".
# Each group fires independently (>=2 clips, distinct authors). The merge pass
# must yield ONE page listing ALL contributors, ONE ledger entry, and revert
# must un-stamp every contributor (no stranded promoted_to).
echo "Test group 4: subject-name collision merge"
tmp4="$(mktemp -d)"
trap 'rm -rf "$tmp" "$tmp4"' EXIT
EV4="$tmp4/Clippings/_evidence"
mkdir -p "$EV4" "$tmp4/30-Resources/Concepts"
mkclip() { # $1=file $2=author $3=url $4=tag
  cat > "$EV4/$1" <<EOF
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
mkclip lf-a.md "Dan Author"   "https://da.com/lf"  "local-first"
mkclip lf-b.md "Eve Author"   "https://ev.com/lf"  "local-first"
mkclip lf-c.md "Frank Author" "https://fr.com/lf"  "local first"
mkclip lf-d.md "Grace Author" "https://gr.com/lf"  "local first"

LEDGER4="$tmp4/.synthesize-stubs.ledger.jsonl"
out4="$(node "$TOOL" "$tmp4" --apply 2>&1)"; printf '%s
' "$out4"

npages="$(find "$tmp4/30-Resources/Concepts" -type f -name '*.md' | wc -l | tr -d ' ')"
assert "collision yields exactly 1 page" "1" "$npages"

nentries="$(grep -cF 'Local First.md' "$LEDGER4" 2>/dev/null || echo 0)"
assert "exactly 1 ledger entry for the merged page" "1" "$nentries"

nstamp="$(grep -lF 'promoted_to:' "$EV4"/lf-*.md 2>/dev/null | wc -l | tr -d ' ')"
assert "all 4 contributors stamped" "4" "$nstamp"

node "$TOOL" "$tmp4" --revert "$LEDGER4" >/dev/null 2>&1
nstamp_after="$(grep -lF 'promoted_to:' "$EV4"/lf-*.md 2>/dev/null | wc -l | tr -d ' ')"
assert "no stranded stamp after revert (all 4 cleared)" "0" "$nstamp_after"

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "test-synthesize-stubs: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
