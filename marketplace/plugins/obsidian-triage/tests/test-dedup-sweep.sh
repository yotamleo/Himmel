#!/usr/bin/env bash
# Smoke tests for LUNA-37 dedup-sweep.mjs.
#
# Scope:
#   - script parses (node --check)
#   - url-canonical.mjs lib parses + per-domain rules match
#     harvest-clip-body-batch.py / playwright-crawl-x.mjs
#   - normaliseBodyForHash strips scaffold headers + collapses whitespace
#   - 4-fixture vault: 2 URL-dupes + 2 content-dupes
#       * --dry-run reports clusters, no writes
#       * real run marks dupes correctly
#       * re-run is idempotent (no new writes)
#   - canonical clip gets re_clipped_by populated
#   - cluster report shape (Phase 3)
#
# Cross-platform: bash on Linux/macOS/Git-Bash. Uses node (not bun) so it
# runs in CI without bun on PATH.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
SCRIPT="$TOOLS_DIR/dedup-sweep.mjs"
LIB="$TOOLS_DIR/lib/url-canonical.mjs"

# Lower the min-content guard for the test fixture (short bodies).
export DEDUP_MIN_CONTENT_BYTES=10

pass=0
fail=0

assert() {
    local desc="$1" expected="$2" actual="$3"
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

# -- Test 1: scripts parse via node --check ---------------------------------
echo "Test 1: scripts parse"
if [ ! -r "$SCRIPT" ]; then
    assert "dedup-sweep.mjs exists" "yes" "no"
else
    assert "dedup-sweep.mjs exists" "yes" "yes"
    if node --check "$SCRIPT" 2>/dev/null; then s1=ok; else s1=fail; fi
    assert "dedup-sweep.mjs parses" "ok" "$s1"
fi
if [ ! -r "$LIB" ]; then
    assert "lib/url-canonical.mjs exists" "yes" "no"
else
    assert "lib/url-canonical.mjs exists" "yes" "yes"
    if node --check "$LIB" 2>/dev/null; then s2=ok; else s2=fail; fi
    assert "lib/url-canonical.mjs parses" "ok" "$s2"
fi

# -- Test 2: js-yaml dep declared in tools/package.json --------------------
echo "Test 2: tools/package.json declares js-yaml"
pkg="$TOOLS_DIR/package.json"
if grep -q '"js-yaml"' "$pkg"; then has_yaml=yes; else has_yaml=no; fi
assert "package.json declares js-yaml" "yes" "$has_yaml"

# -- Test 3: canonicalisation rules -----------------------------------------
echo "Test 3: canonicalize() per-domain rules"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

lib_url="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$LIB")"
cat >"$tmpdir/canon-test.mjs" <<EOF
import { canonicalize } from "$lib_url";

const cases = [
  ["https://twitter.com/jack/status/20?s=09",        "https://x.com/jack/status/20"],
  ["https://mobile.twitter.com/jack/status/20",      "https://x.com/jack/status/20"],
  ["https://x.com/jack/status/20",                   "https://x.com/jack/status/20"],
  ["https://www.x.com/jack/status/20",               "https://x.com/jack/status/20"],
  ["https://youtu.be/dQw4w9WgXcQ?t=10",              "https://youtube.com/watch?v=dQw4w9WgXcQ"],
  ["https://www.youtube.com/watch?v=ABCD&feature=x", "https://youtube.com/watch?v=ABCD"],
  ["https://github.com/Foo/Bar/tree/main/sub",       "https://github.com/foo/bar"],
  ["https://github.com/Foo/Bar/blob/main/x.md",      "https://github.com/foo/bar"],
  ["https://github.com/Foo/Bar/",                    "https://github.com/foo/bar"],
  ["https://medium.com/path?source=tw",              "https://medium.com/path"],
  ["https://example.com/x?utm_source=tw&keep=1",     "https://example.com/x?keep=1"],
  ["https://example.com/x?fbclid=abc",               "https://example.com/x"],
  ["not a url at all",                                null],
];
let ok = 0, bad = 0;
for (const [input, expected] of cases) {
  const got = canonicalize(input);
  if (got === expected) {
    ok++;
  } else {
    bad++;
    console.log("MISMATCH input=" + JSON.stringify(input) + " expected=" + JSON.stringify(expected) + " got=" + JSON.stringify(got));
  }
}
console.log("CANON_OK=" + ok);
console.log("CANON_BAD=" + bad);
EOF
canon_out="$(node "$tmpdir/canon-test.mjs" 2>&1)"
canon_bad="$(echo "$canon_out" | grep -oE 'CANON_BAD=[0-9]+' | cut -d= -f2)"
assert "canonicalize: 13/13 cases match" "0" "${canon_bad:-99}"

# -- Test 4: normaliseBodyForHash collapses noise --------------------------
echo "Test 4: normaliseBodyForHash"
script_url="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$SCRIPT")"
cat >"$tmpdir/norm-test.mjs" <<EOF
import { normaliseBodyForHash } from "$script_url";

const a = \`# Title

## The Idea
Hello   world.

![image](https://x.com/foo.jpg)
[[ ]]

## Source
extra
\`;
const b = \`# Title

## Highlights
Hello world.

[[]]

## Comments
extra
\`;
const c = "completely different";
const ha = normaliseBodyForHash(a);
const hb = normaliseBodyForHash(b);
const hc = normaliseBodyForHash(c);
console.log("A_EQ_B=" + (ha === hb ? "yes" : "no"));
console.log("A_NEQ_C=" + (ha === hc ? "no" : "yes"));
console.log("A=" + JSON.stringify(ha));
console.log("B=" + JSON.stringify(hb));
EOF
norm_out="$(node "$tmpdir/norm-test.mjs" 2>&1)"
echo "$norm_out" | grep -q 'A_EQ_B=yes' && r_eq=yes || r_eq=no
echo "$norm_out" | grep -q 'A_NEQ_C=yes' && r_neq=yes || r_neq=no
assert "norm: equivalent-scaffold bodies hash-equal" "yes" "$r_eq"
assert "norm: different bodies hash-unequal"        "yes" "$r_neq"
if [ "$r_eq" != "yes" ]; then
    while IFS= read -r line; do echo "    $line"; done <<< "$norm_out"
fi

# -- Test 5: 4-clip fixture sweep — URL + content dedup -------------------
echo "Test 5: 4-clip fixture sweep"
vault="$tmpdir/vault"
mkdir -p "$vault/Clippings" "$vault/60-Maps"

# Two URL-dupes — same canonical URL after normalisation. Different filenames.
cat >"$vault/Clippings/url-dupe-A.md" <<'EOF'
---
title: "Post A"
source: "https://twitter.com/jack/status/12345?s=09"
date_clipped: 2026-05-20
harvest_url_canonical: "https://x.com/jack/status/12345"
harvest_status: ok
processed: true
---
Body of A.
EOF
cat >"$vault/Clippings/url-dupe-B.md" <<'EOF'
---
title: "Post B"
source: "https://x.com/jack/status/12345"
date_clipped: 2026-05-25
harvest_url_canonical: "https://x.com/jack/status/12345"
harvest_status: ok
processed: true
---
Body of B.
EOF

# Two content-dupes — different URLs but body normalises identically.
cat >"$vault/Clippings/content-dupe-A.md" <<'EOF'
---
title: "Content A"
source: "https://example.com/a"
date_clipped: 2026-05-21
harvest_url_canonical: "https://example.com/a"
harvest_status: ok
processed: true
---
## The Idea
Same body content.

![image](x.png)
EOF
cat >"$vault/Clippings/content-dupe-B.md" <<'EOF'
---
title: "Content B"
source: "https://example.com/b"
date_clipped: 2026-05-26
harvest_url_canonical: "https://example.com/b"
harvest_status: ok
processed: true
---
## Highlights
Same body content.

![image](y.png)
EOF

before_a="$(sha256sum "$vault/Clippings/url-dupe-A.md" | cut -d' ' -f1)"

# -- 5a: --dry-run reports clusters, no writes -----------------------------
out_dry="$(node "$SCRIPT" --vault "$vault" --dry-run 2>&1)"
dry_rc=$?
after_a="$(sha256sum "$vault/Clippings/url-dupe-A.md" | cut -d' ' -f1)"
assert "5a: --dry-run exit 0"                "0" "$dry_rc"
assert "5a: --dry-run leaves clip identical" "$before_a" "$after_a"
echo "$out_dry" | grep -q '1 clusters' && r=yes || r=no
assert "5a: --dry-run reports 1 url cluster"  "yes" "$r"

# Idempotency baseline — count "wrote" outcomes on second run.

# -- 5b: real run mutates dupes -------------------------------------------
node "$SCRIPT" --vault "$vault" >/dev/null 2>&1
real_rc=$?
assert "5b: real run exit 0" "0" "$real_rc"

# url-dupe-B is newer → should be marked dupe pointing at url-dupe-A.
if grep -q 'harvest_dedup_target: "\[\[Clippings/url-dupe-A\]\]"' "$vault/Clippings/url-dupe-B.md"; then
    r=yes; else r=no; fi
assert "5b: url-dupe-B marked with harvest_dedup_target → url-dupe-A" "yes" "$r"

if grep -q 'harvest_status: dedup' "$vault/Clippings/url-dupe-B.md"; then r=yes; else r=no; fi
assert "5b: url-dupe-B harvest_status: dedup" "yes" "$r"

if grep -q "dedup_detected_at:" "$vault/Clippings/url-dupe-B.md"; then r=yes; else r=no; fi
assert "5b: url-dupe-B has dedup_detected_at" "yes" "$r"

# url-dupe-A (canonical) gets re_clipped_by block-list.
if grep -q '^re_clipped_by:' "$vault/Clippings/url-dupe-A.md"; then r=yes; else r=no; fi
assert "5b: canonical (url-dupe-A) has re_clipped_by" "yes" "$r"
if grep -q '"\[\[Clippings/url-dupe-B\]\]"' "$vault/Clippings/url-dupe-A.md"; then r=yes; else r=no; fi
assert "5b: canonical re_clipped_by lists url-dupe-B" "yes" "$r"

# content-dupe-B should be marked content_dedup pointing at content-dupe-A.
if grep -q 'content_dedup_target: "\[\[Clippings/content-dupe-A\]\]"' "$vault/Clippings/content-dupe-B.md"; then
    r=yes; else r=no; fi
assert "5b: content-dupe-B marked with content_dedup_target" "yes" "$r"

if grep -q 'harvest_status: content_dedup' "$vault/Clippings/content-dupe-B.md"; then r=yes; else r=no; fi
assert "5b: content-dupe-B harvest_status: content_dedup" "yes" "$r"

# Cluster report should exist.
cluster_count=$(find "$vault/60-Maps" -maxdepth 1 -name 'dedup-clusters-*.md' -type f 2>/dev/null | wc -l)
if [ "$cluster_count" -ge 1 ]; then r=yes; else r=no; fi
assert "5b: cluster report written to 60-Maps/" "yes" "$r"

# G-3 sanity: body of url-dupe-B should still be "Body of B."
body_b="$(awk 'BEGIN{p=0} /^---$/{c++; if(c==2){p=1; next}} p{print}' "$vault/Clippings/url-dupe-B.md")"
expected_body="Body of B."
got_body="$(echo "$body_b" | head -1)"
assert "5b: G-3 body identity post-write" "$expected_body" "$got_body"

# -- 5c: re-run is idempotent ---------------------------------------------
before_b_sha="$(sha256sum "$vault/Clippings/url-dupe-B.md" | cut -d' ' -f1)"
before_canonical_sha="$(sha256sum "$vault/Clippings/url-dupe-A.md" | cut -d' ' -f1)"
out_rerun="$(node "$SCRIPT" --vault "$vault" 2>&1)"
rerun_rc=$?
assert "5c: re-run exit 0" "0" "$rerun_rc"
after_b_sha="$(sha256sum "$vault/Clippings/url-dupe-B.md" | cut -d' ' -f1)"
after_canonical_sha="$(sha256sum "$vault/Clippings/url-dupe-A.md" | cut -d' ' -f1)"
assert "5c: re-run leaves dupe identical"      "$before_b_sha" "$after_b_sha"
assert "5c: re-run leaves canonical identical" "$before_canonical_sha" "$after_canonical_sha"
# Stdout summary should report 0 writes.
echo "$out_rerun" | grep -qE '0 writes' && r=yes || r=no
assert "5c: re-run summary reports 0 writes" "yes" "$r"

# -- Test 6: --report-only mode ---------------------------------------------
echo "Test 6: --report-only mode"
vault2="$tmpdir/vault2"
mkdir -p "$vault2/Clippings" "$vault2/60-Maps"
cp "$vault/Clippings/url-dupe-A.md.bak" "$vault2/Clippings/" 2>/dev/null || true
cat >"$vault2/Clippings/clip-A.md" <<'EOF'
---
source: "https://x.com/jack/status/99"
date_clipped: 2026-05-20
processed: true
---
Body.
EOF
cat >"$vault2/Clippings/clip-B.md" <<'EOF'
---
source: "https://x.com/jack/status/99"
date_clipped: 2026-05-21
processed: true
---
Body.
EOF
before_a2="$(sha256sum "$vault2/Clippings/clip-A.md" | cut -d' ' -f1)"
node "$SCRIPT" --vault "$vault2" --report-only >/dev/null 2>&1
after_a2="$(sha256sum "$vault2/Clippings/clip-A.md" | cut -d' ' -f1)"
assert "6: --report-only leaves clips identical" "$before_a2" "$after_a2"
cluster_count2=$(find "$vault2/60-Maps" -maxdepth 1 -name 'dedup-clusters-*.md' -type f 2>/dev/null | wc -l)
if [ "$cluster_count2" -ge 1 ]; then r=yes; else r=no; fi
assert "6: --report-only writes 60-Maps report" "yes" "$r"

# -- Test 6b: min-content guard blocks empty-body false positives ----------
echo "Test 6b: min-content guard (DEDUP_MIN_CONTENT_BYTES)"
vault3="$tmpdir/vault3"
mkdir -p "$vault3/Clippings" "$vault3/60-Maps"
# Two scaffold-only clips with DIFFERENT URLs but near-empty bodies.
cat >"$vault3/Clippings/empty-A.md" <<'EOF'
---
source: "https://example.com/a"
processed: true
---
## The Idea

EOF
cat >"$vault3/Clippings/empty-B.md" <<'EOF'
---
source: "https://example.com/b"
processed: true
---
## Highlights

EOF
# With a high threshold these should NOT cluster.
DEDUP_MIN_CONTENT_BYTES=200 node "$SCRIPT" --vault "$vault3" --phase content --dry-run 2>&1 | tee "$tmpdir/min-out.log" >/dev/null
if grep -q "content phase: 0 clusters" "$tmpdir/min-out.log"; then r=yes; else r=no; fi
assert "6b: min-content guard blocks tiny-body clusters" "yes" "$r"

# -- Test 7: G-3 invariant assertion present in source ---------------------
echo "Test 7: G-3 invariant in script"
if grep -q 'G-3' "$SCRIPT" && grep -q 'reverted' "$SCRIPT"; then has_g3=yes; else has_g3=no; fi
assert "G-3 + revert paths in script" "yes" "$has_g3"

# -- Summary --------------------------------------------------------------
total=$((pass + fail))
echo ""
echo "Results: $pass / $total passed, $fail failed."
[ "$fail" -eq 0 ]
