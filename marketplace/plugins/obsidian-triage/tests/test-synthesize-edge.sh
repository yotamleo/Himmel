#!/usr/bin/env bash
# Edge-case + safety-property coverage for synthesize-stubs (LUNA-87/88/89),
# closing the gaps the CR test-analyzer flagged: CRLF byte round-trip, the
# distinct-source OR-gate legs + floor-skip, compound stub->densify revert,
# densify idempotency, Tech-vs-Concept boundary, _deferred.md sibling-prefix +
# densify-claim + revert-when-regenerated, and cross-subject promoted_to.

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

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

# clip writer: $1=dir $2=file $3=author $4=url $5=tag(s, comma) [$6=eol(crlf|lf)]
mkclip() {
  local dir="$1" file="$2" author="$3" url="$4" tagcsv="$5" eol="${6:-lf}"
  local tags="" t
  IFS=',' read -ra arr <<< "$tagcsv"
  for t in "${arr[@]}"; do tags+="  - $t"$'\n'; done
  local body
  body="---
type: article
source: \"$url\"
author: $author
processed: true
evidence_kind:
  - concepts
tags:
${tags}---
clip $file"
  if [ "$eol" = "crlf" ]; then
    printf '%s' "$body" | sed 's/$/\r/' > "$dir/$file"
  else
    printf '%s\n' "$body" > "$dir/$file"
  fi
}

# ── Group 1: CRLF byte round-trip (create + stamp + revert = byte-identical) ──
echo "Group 1: CRLF byte round-trip"
v1="$root/v1"; mkdir -p "$v1/Clippings/_evidence" "$v1/30-Resources/Concepts"
mkclip "$v1/Clippings/_evidence" cr1.md "Ada L" "https://crlf-a.com/x" "crlf-topic" crlf
mkclip "$v1/Clippings/_evidence" cr2.md "Ben K" "https://crlf-b.com/y" "crlf-topic" crlf
cp "$v1/Clippings/_evidence/cr1.md" "$root/cr1.orig"
cp "$v1/Clippings/_evidence/cr2.md" "$root/cr2.orig"
# confirm the fixtures really are CRLF
if grep -qU $'\r' "$v1/Clippings/_evidence/cr1.md"; then f=yes; else f=no; fi
assert "fixture clips are CRLF" "yes" "$f"
node "$TOOL" "$v1" --apply >/dev/null 2>&1
if grep -qF 'promoted_to:' "$v1/Clippings/_evidence/cr1.md"; then f=yes; else f=no; fi
assert "CRLF clip stamped on apply" "yes" "$f"
node "$TOOL" "$v1" --revert "$v1/.synthesize-stubs.ledger.jsonl" >/dev/null 2>&1
if cmp -s "$root/cr1.orig" "$v1/Clippings/_evidence/cr1.md" && cmp -s "$root/cr2.orig" "$v1/Clippings/_evidence/cr2.md"; then f=identical; else f=changed; fi
assert "CRLF clips byte-identical after stamp+revert round-trip" "identical" "$f"

# ── Group 2: distinct-source OR-gate (each leg + floor-skip) ──────────────────
echo "Group 2: distinct-source OR-gate"
v2="$root/v2"; mkdir -p "$v2/Clippings/_evidence" "$v2/30-Resources/Concepts"
# (a) same author, 2 domains -> fires
mkclip "$v2/Clippings/_evidence" a1.md "Sam One" "https://ad1.com/p" "gate-a"
mkclip "$v2/Clippings/_evidence" a2.md "Sam One" "https://ad2.com/p" "gate-a"
# (b) 2 authors, same domain (distinct paths) -> fires
mkclip "$v2/Clippings/_evidence" b1.md "Pat A" "https://onedom.com/1" "gate-b"
mkclip "$v2/Clippings/_evidence" b2.md "Quinn B" "https://onedom.com/2" "gate-b"
# (c) same author, same domain, distinct URLs -> SKIP (floor)
mkclip "$v2/Clippings/_evidence" c1.md "Sam One" "https://samedom.com/1" "gate-c"
mkclip "$v2/Clippings/_evidence" c2.md "Sam One" "https://samedom.com/2" "gate-c"
out2="$(node "$TOOL" "$v2" --apply 2>&1)"
if [ -f "$v2/30-Resources/Concepts/Gate A.md" ]; then f=yes; else f=no; fi
assert "(a) same-author/2-domains fires" "yes" "$f"
if [ -f "$v2/30-Resources/Concepts/Gate B.md" ]; then f=yes; else f=no; fi
assert "(b) 2-authors/same-domain fires" "yes" "$f"
if [ -f "$v2/30-Resources/Concepts/Gate C.md" ]; then f=fired; else f=skipped; fi
assert "(c) same-author/same-domain SKIPPED (floor)" "skipped" "$f"
if echo "$out2" | grep -qF 'distinct-source floor'; then f=yes; else f=no; fi
assert "(c) skip reason is distinct-source floor" "yes" "$f"

# ── Group 3: compound stub -> densify-same-page -> revert ─────────────────────
echo "Group 3: compound stub->densify revert"
v3="$root/v3"; mkdir -p "$v3/Clippings/_evidence" "$v3/30-Resources/Concepts"
mkclip "$v3/Clippings/_evidence" k1.md "Ed A" "https://k1.com/x" "compound"
mkclip "$v3/Clippings/_evidence" k2.md "Fi B" "https://k2.com/y" "compound"
node "$TOOL" "$v3" --apply >/dev/null 2>&1        # creates Compound stub
mkclip "$v3/Clippings/_evidence" k3.md "Gus C" "https://k3.com/z" "compound"
node "$TOOL" "$v3" --apply >/dev/null 2>&1        # densifies same page with k3
stubc="$v3/30-Resources/Concepts/Compound.md"
if grep -qF '[[Clippings/_evidence/k3]]' "$stubc"; then f=yes; else f=no; fi
assert "compound page densified with the 3rd clip" "yes" "$f"
node "$TOOL" "$v3" --revert "$v3/.synthesize-stubs.ledger.jsonl" >/dev/null 2>&1
if [ -f "$stubc" ]; then f=present; else f=removed; fi
assert "compound page fully removed after chained revert" "removed" "$f"
nstamp3="$(grep -lF 'promoted_to:' "$v3/Clippings/_evidence"/k*.md 2>/dev/null | wc -l | tr -d ' ')"
assert "all 3 compound contributors unstamped after revert" "0" "$nstamp3"

# ── Group 4: densify re-apply idempotency (no dup ledger, byte-identical) ─────
echo "Group 4: densify re-apply idempotency"
v4="$root/v4"; mkdir -p "$v4/Clippings/_evidence" "$v4/60-Maps"
mkclip "$v4/Clippings/_evidence" d1.md "Hank A" "https://d1.com/x" "idem"
mkclip "$v4/Clippings/_evidence" d2.md "Ivy B" "https://d2.com/y" "idem"
printf -- '---\ntype: moc\n---\n# Idem MOC\n\n## Evidence\n\n- seed\n' > "$v4/60-Maps/Idem-MOC.md"
node "$TOOL" "$v4" --apply >/dev/null 2>&1
cp "$v4/60-Maps/Idem-MOC.md" "$root/idem.after1"
n_dens_1="$(grep -c '"action":"densify"' "$v4/.synthesize-stubs.ledger.jsonl")"
node "$TOOL" "$v4" --apply >/dev/null 2>&1        # second apply: nothing fresh
n_dens_2="$(grep -c '"action":"densify"' "$v4/.synthesize-stubs.ledger.jsonl")"
assert "second apply adds no new densify ledger entry" "$n_dens_1" "$n_dens_2"
if cmp -s "$root/idem.after1" "$v4/60-Maps/Idem-MOC.md"; then f=identical; else f=changed; fi
assert "densified MOC byte-identical on re-apply" "identical" "$f"

# ── Group 5: Tech-vs-Concept majority boundary (1 repo + 2 articles -> Concept) ─
echo "Group 5: Tech-vs-Concept boundary"
v5="$root/v5"; mkdir -p "$v5/Clippings/_evidence" "$v5/30-Resources/Concepts" "$v5/30-Resources/Tech"
mkclip "$v5/Clippings/_evidence" m1.md "Jo A" "https://github.com/o/repo" "boundary"
mkclip "$v5/Clippings/_evidence" m2.md "Ka B" "https://art1.com/p" "boundary"
mkclip "$v5/Clippings/_evidence" m3.md "Lo C" "https://art2.com/q" "boundary"
node "$TOOL" "$v5" --apply >/dev/null 2>&1
if [ -f "$v5/30-Resources/Concepts/Boundary.md" ]; then f=concept; elif [ -f "$v5/30-Resources/Tech/Boundary.md" ]; then f=tech; else f=none; fi
assert "minority-repo group routes to Concept" "concept" "$f"
if grep -qF 'deepen_pending' "$v5/30-Resources/Concepts/Boundary.md" 2>/dev/null; then f=yes; else f=no; fi
assert "Concept route has no deepen_pending marker" "no" "$f"

# ── Group 6: _deferred.md sibling-prefix + densify-claim + revert-when-gone ───
echo "Group 6: _deferred.md edges"
v6="$root/v6"; mkdir -p "$v6/Clippings/_evidence" "$v6/30-Resources/Tech"
mkclip "$v6/Clippings/_evidence" g1.md "Mo A" "https://github.com/acme/agent-kit" "fanout"
mkclip "$v6/Clippings/_evidence" g2.md "Ng B" "https://github.com/zeta/orchestrator" "fanout"
# pre-existing Tech subject so this is the DENSIFY path (regression for the
# MEDIUM finding: densify must also claim deferred rows).
printf -- '---\ntype: tech-ingest\nstatus: stub\ndeepen_pending: true\n---\n# Fanout\n\n## References\n\n<!-- pending -->\n\n## Evidence\n\n- seed\n' > "$v6/30-Resources/Tech/Fanout.md"
cat > "$v6/Clippings/_deferred.md" <<'EOF'
---
type: pipeline-deferred
---
## Tail-skipped refs (luna-ingest --limit cap)
- [ ] acme/agent-kit — 178 refs beyond --limit; re-run `/luna-ingest https://github.com/acme/agent-kit --limit 200`
- [ ] acme/agent-kit-extra — 5 refs beyond --limit; re-run `/luna-ingest https://github.com/acme/agent-kit-extra --limit 200`
- [ ] zeta/orchestrator — 89 refs beyond --limit; re-run `/luna-ingest https://github.com/zeta/orchestrator --limit 200`
EOF
node "$TOOL" "$v6" --apply >/dev/null 2>&1
defA="$(grep -cE '^\- \[x\] acme/agent-kit ' "$v6/Clippings/_deferred.md" 2>/dev/null || echo 0)"
assert "DENSIFY path claims acme/agent-kit row (MEDIUM regression)" "1" "$defA"
sib="$(grep -cE '^\- \[ \] acme/agent-kit-extra' "$v6/Clippings/_deferred.md" 2>/dev/null || echo 0)"
assert "sibling-prefix acme/agent-kit-extra row untouched" "1" "$sib"
# revert-when-regenerated: mutate the claimed line so the recorded newLine is gone
sed -i 's/^- \[x\] acme\/agent-kit .*/- [ ] acme\/agent-kit — REGENERATED/' "$v6/Clippings/_deferred.md"
rv6="$(node "$TOOL" "$v6" --revert "$v6/.synthesize-stubs.ledger.jsonl" 2>&1)"
if echo "$rv6" | grep -qiE 'no longer present|regenerated|skipping'; then f=yes; else f=no; fi
assert "revert gracefully skips a regenerated _deferred row" "yes" "$f"

# ── Group 7: cross-subject promoted_to (shared clip stamped once) ─────────────
echo "Group 7: cross-subject promoted_to"
v7="$root/v7"; mkdir -p "$v7/Clippings/_evidence" "$v7/30-Resources/Concepts"
mkclip "$v7/Clippings/_evidence" x.md  "Shared A" "https://xx.com/0" "topic-one,topic-two"
mkclip "$v7/Clippings/_evidence" o1.md "Bee B"    "https://o1.com/1" "topic-one"
mkclip "$v7/Clippings/_evidence" o2.md "Cee C"    "https://o2.com/2" "topic-two"
node "$TOOL" "$v7" --apply >/dev/null 2>&1
nx="$(grep -cF 'promoted_to:' "$v7/Clippings/_evidence/x.md")"
assert "shared clip stamped exactly once (first subject wins)" "1" "$nx"
if grep -qF 'Topic One' "$v7/Clippings/_evidence/x.md"; then f=yes; else f=no; fi
assert "shared clip stamp points at the alphabetically-first subject" "yes" "$f"
# ledger: the second subject's entry lists x.md in `contributors` but NOT in
# `stamped` (it was already stamped by the first subject). Isolate the stamped
# array so the contributors entry doesn't false-match.
t2line="$(grep -F 'Topic Two' "$v7/.synthesize-stubs.ledger.jsonl" | head -1)"
t2stamped="$(echo "$t2line" | grep -oE '"stamped":\[[^]]*\]')"
if echo "$t2stamped" | grep -qF '_evidence/x.md'; then f=present; else f=absent; fi
assert "second subject's stamped[] excludes the already-stamped clip" "absent" "$f"

echo ""
echo "test-synthesize-edge: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
