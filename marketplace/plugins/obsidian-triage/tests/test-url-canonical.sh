#!/usr/bin/env bash
# Tests for lib/url-canonical.mjs — reddit string rule (HIMMEL-769) plus a
# couple of guard cases. Pure string surgery; no I/O.
set -u -o pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../tools/lib/url-canonical.mjs"
LIBURL="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$lib")"

pass=0; fail=0
assert() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "  PASS  $desc"; pass=$((pass+1));
  else echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1)); fi
}
canon() { IN="$1" LIB="$LIBURL" node --input-type=module -e '
const {canonicalize} = await import(process.env.LIB);
console.log(canonicalize(process.env.IN));'; }

node --check "$lib" || { echo "FAIL: url-canonical.mjs does not parse"; exit 1; }

assert "reddit host normalizes to www + drops query" \
  "https://www.reddit.com/r/machinelearning/comments/abc123/some_title" \
  "$(canon 'https://old.reddit.com/r/MachineLearning/comments/abc123/some_title/?utm_source=share')"
assert "reddit strips trailing slash" \
  "https://www.reddit.com/r/foo/comments/xyz/t" \
  "$(canon 'https://www.reddit.com/r/foo/comments/xyz/t/')"
assert "reddit lowercases subreddit segment only" \
  "https://www.reddit.com/r/askscience/comments/9/Title_Case_Kept" \
  "$(canon 'https://reddit.com/r/AskScience/comments/9/Title_Case_Kept')"
# redd.it is NOT handled here (generic passthrough) — reddit-enrich resolves it.
assert "redd.it not expanded (generic passthrough)" \
  "https://redd.it/abc123" \
  "$(canon 'https://redd.it/abc123')"

echo ""
echo "url-canonical tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
