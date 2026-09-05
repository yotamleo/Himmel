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

# github: /blob/<branch>/<path> is a distinct FILE, /tree/<branch> is a repo view (HIMMEL-1735).
assert "github keeps /blob/<branch>/<path>" \
  "https://github.com/anthropics/claude-cookbooks/blob/main/claude_agent_sdk/08_Dynamic_workflows.ipynb" \
  "$(canon 'https://github.com/anthropics/claude-cookbooks/blob/main/claude_agent_sdk/08_Dynamic_workflows.ipynb')"
assert "github /blob/ does NOT collapse to the repo root" \
  "https://github.com/o/r/blob/main/a.md" \
  "$(canon 'https://github.com/o/r/blob/main/a.md')"
assert "github two files in one repo stay distinct" \
  "https://github.com/o/r/blob/main/b.md" \
  "$(canon 'https://github.com/o/r/blob/main/b.md')"
assert "github lowercases owner/repo but not the blob path" \
  "https://github.com/anthropics/claude-cookbooks/blob/main/Dir/File.ipynb" \
  "$(canon 'https://github.com/Anthropics/Claude-Cookbooks/blob/main/Dir/File.ipynb')"
assert "github still strips /tree/<branch>" \
  "https://github.com/o/r" \
  "$(canon 'https://github.com/o/r/tree/main')"
assert "github still strips /tree/<branch>/<subdir>" \
  "https://github.com/o/r" \
  "$(canon 'https://github.com/o/r/tree/main/some/dir')"
assert "github repo root unchanged + trailing slash stripped" \
  "https://github.com/o/r" \
  "$(canon 'https://github.com/o/r/')"

# --- JS <-> Python parity (HIMMEL-1735) -------------------------------------
# harvest-clip-body-batch.py carries a hand-written mirror of these rules. Three
# copies of one rule drift silently; assert the two executable ones agree.
py="$here/../tools/harvest-clip-body-batch.py"
pycanon() { IN="$1" PYMOD="$py" python -c '
import importlib.util, os
spec = importlib.util.spec_from_file_location("hcb", os.environ["PYMOD"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.canonicalize(os.environ["IN"]))'; }

if command -v python >/dev/null 2>&1; then
  for url in \
    'https://github.com/Anthropics/Claude-Cookbooks/blob/main/claude_agent_sdk/08_Dynamic_workflows.ipynb' \
    'https://github.com/o/r/blob/main/a.md' \
    'https://github.com/o/r/tree/main' \
    'https://github.com/o/r/tree/main/some/dir' \
    'https://github.com/o/r/'
  do
    assert "js/py parity: $url" "$(canon "$url")" "$(pycanon "$url")"
  done
else
  echo "  SKIP  js/py parity (no python on PATH)"
fi

echo ""
echo "url-canonical tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
