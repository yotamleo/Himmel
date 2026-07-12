#!/usr/bin/env bash
# Smoke test for scripts/cr/emit-gate-fail.sh (HIMMEL-654 WS7, spec D6).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/emit-gate-fail.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
check() { [ "$1" = "$2" ] || { echo "FAIL: got '$1' want '$2'"; fail=1; }; }

cat > "$tmp/cr.txt" <<'EOF'
- scripts/foo.sh:42: CRITICAL: unquoted expansion. Quote it.
- docs/readme.md:3: NIT: trailing space. Trim it.
* lib/bar.ts:10: IMPORTANT: missing null check. Guard it.
EOF

# cheap-glm branch → blocking findings emitted, NIT dropped
bash "$SCRIPT" --session-dir "$tmp" --input "$tmp/cr.txt" --branch glm/spike >/dev/null
n="$(wc -l < "$tmp/gate-report.jsonl" | tr -d ' ')"
check "$n" "2"
grep -q 'CRITICAL' "$tmp/gate-report.jsonl" || { echo "FAIL: CRITICAL missing"; fail=1; }
grep -q 'scripts/foo.sh:42' "$tmp/gate-report.jsonl" || { echo "FAIL: file:line missing"; fail=1; }
grep -q 'NIT' "$tmp/gate-report.jsonl" && { echo "FAIL: NIT should be excluded"; fail=1; }

# idempotent: second run does not duplicate
bash "$SCRIPT" --session-dir "$tmp" --input "$tmp/cr.txt" --branch glm/spike >/dev/null
n2="$(wc -l < "$tmp/gate-report.jsonl" | tr -d ' ')"
check "$n2" "2"

# claude-lane branch → nothing emitted (D6 is cheap-lane only)
tmp2="$(mktemp -d)"; printf '{}' > "$tmp2/meta.json"
bash "$SCRIPT" --session-dir "$tmp2" --input "$tmp/cr.txt" --branch feat/x >/dev/null
[ -f "$tmp2/gate-report.jsonl" ] && { echo "FAIL: claude lane should emit nothing"; fail=1; }
rm -rf "$tmp2"
[ "$fail" -eq 0 ] && echo "PASS test-emit-gate-fail" || exit 1
