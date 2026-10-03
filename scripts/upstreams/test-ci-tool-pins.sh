#!/usr/bin/env bash
# scripts/upstreams/test-ci-tool-pins.sh — every CI bun install is pinned (HIMMEL-4258).
#
# An unpinned `oven-sh/setup-bun` lists bun's tags through api.github.com and
# dies on a 503 before any test runs; an exact version (or the repo-root
# .bun-version via bun-version-file) skips that call. This keeps a NEW setup-bun
# step from regressing it. The lint itself is exercised on a fixture first, so a
# check that cannot fail is caught.
#
# bash 3.2-safe. Hermetic: reads only files in this repo.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fails=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fails=$((fails + 1)); }

# unpinned_setup_bun <workflow-file>: print "<line>" of each setup-bun step that
# carries neither an exact bun-version nor bun-version-file in its with: block.
unpinned_setup_bun() {
  python3 - "$1" <<'PY'
import re, sys

lines = open(sys.argv[1]).read().splitlines()
for i, ln in enumerate(lines):
    m = re.match(r"^(\s*)-\s+uses:\s*oven-sh/setup-bun@", ln)
    if not m:
        continue
    indent = len(m.group(1))
    block = []
    for nxt in lines[i + 1:]:
        if nxt.strip() and (len(nxt) - len(nxt.lstrip())) <= indent:
            break
        block.append(nxt)
    text = "\n".join(block)
    if re.search(r"^\s*bun-version-file:\s*\.bun-version\s*$", text, re.M):
        continue
    if re.search(r"^\s*bun-version:\s*['\"]?\d+\.\d+\.\d+['\"]?\s*$", text, re.M):
        continue
    print(i + 1)
PY
}

echo "[test-ci-tool-pins] lint control (a fixture that MUST be flagged)"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/ci-tool-pins.XXXXXX") || exit 1
cat > "$FIX/bad.yml" <<'YML'
jobs:
  a:
    steps:
      - uses: oven-sh/setup-bun@v2
      - run: bun test
  b:
    steps:
      - uses: oven-sh/setup-bun@v2
        with:
          bun-version: latest
      - uses: oven-sh/setup-bun@v2
        with:
          bun-version-file: .bun-version
      - uses: oven-sh/setup-bun@v2
        with:
          bun-version: 1.4.2
YML
got=$(unpinned_setup_bun "$FIX/bad.yml" | tr '\n' ' ')
if [ "$got" = "4 8 " ]; then ok "unpinned and 'latest' steps flagged, file/exact pins pass"; else bad "lint control wrong: flagged '$got' expected '4 8 '"; fi
rm -rf "$FIX"

echo "[test-ci-tool-pins] every setup-bun step in .github/workflows is pinned"
total=0
for wf in "$ROOT"/.github/workflows/*.yml; do
  n=$(grep -cE '^[[:space:]]*-[[:space:]]+uses:[[:space:]]*oven-sh/setup-bun@' "$wf")
  total=$((total + n))
  flagged=$(unpinned_setup_bun "$wf" | tr '\n' ' ')
  if [ -n "$flagged" ]; then bad "$(basename "$wf"): unpinned setup-bun at line(s) $flagged"; fi
done
if [ "$total" -ge 1 ]; then ok "scanned $total setup-bun step(s)"; else bad "found no setup-bun step: the scan is vacuous"; fi

echo "[test-ci-tool-pins] .bun-version is an exact semver"
if [ -f "$ROOT/.bun-version" ] && grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' "$ROOT/.bun-version"; then ok ".bun-version holds a bare x.y.z"; else bad ".bun-version missing or not a bare x.y.z"; fi

echo "[test-ci-tool-pins] .bun-version and the drift registry agree"
reg=$(python3 -c "
import json, sys
for e in json.load(open(sys.argv[1]))['entries']:
    if e.get('name') == 'bun-ci':
        print(e['synced_base'])
" "$ROOT/scripts/upstreams.json")
if [ -n "$reg" ] && [ "$reg" = "$(tr -d '[:space:]' < "$ROOT/.bun-version")" ]; then ok "synced_base $reg matches .bun-version"; else bad "bun-ci synced_base '$reg' != .bun-version"; fi

echo "[test-ci-tool-pins] pip installs in workflows are pinned"
if grep -nE 'pip install .*pre-commit($|[^=-])' "$ROOT"/.github/workflows/*.yml >/dev/null; then bad "an unpinned 'pip install pre-commit' remains"; else ok "pre-commit pip installs are pinned"; fi

echo ""
if [ "$fails" -eq 0 ]; then echo "[test-ci-tool-pins] all checks passed"; exit 0; fi
echo "[test-ci-tool-pins] $fails check(s) FAILED"
exit 1
