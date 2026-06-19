#!/usr/bin/env bash
# Tests for check-vendor-drift.sh
# Run from the repo root: bash marketplace/plugins/obsidian-triage/tests/test-vault-lint-drift.sh
set -euo pipefail

# This test lives at: marketplace/plugins/obsidian-triage/tests/test-vault-lint-drift.sh
# The skill dir is:   marketplace/plugins/obsidian-triage/skills/vault-lint/
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/../skills/vault-lint" && pwd)"
DRIFT_SCRIPT="$SKILL_DIR/check-vendor-drift.sh"
UPSTREAM_JSON="$SKILL_DIR/UPSTREAM.json"

PASS=0
FAIL=0

ok() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

echo "=== vault-lint drift guard tests ==="

# --- Test 1: tampered hash → --strict exits non-zero with the warning ---
echo ""
echo "Test 1: tampered UPSTREAM.json → --strict should exit non-zero with warning"

TMPDIR_TEST="$(mktemp -d)"
TAMPERED_JSON="$TMPDIR_TEST/UPSTREAM.json"
TAMPERED_SKILL_DIR="$TMPDIR_TEST/skills/vault-lint"
mkdir -p "$TAMPERED_SKILL_DIR"

# Write tampered UPSTREAM.json with a wrong sha256 for SKILL.md
python -c "
import json, sys
d = json.load(open(sys.argv[1]))
# corrupt first file hash
d['files'][0]['sha256'] = 'deadbeef' * 8
print(json.dumps(d, indent=2))
" "$UPSTREAM_JSON" > "$TAMPERED_JSON"

# Copy tampered UPSTREAM.json next to a copy of the drift script in tmp
cp "$DRIFT_SCRIPT" "$TAMPERED_SKILL_DIR/check-vendor-drift.sh"
cp "$TAMPERED_JSON" "$TAMPERED_SKILL_DIR/UPSTREAM.json"

OUTPUT="$(bash "$TAMPERED_SKILL_DIR/check-vendor-drift.sh" --strict 2>&1)" && EXIT_CODE=0 || EXIT_CODE=$?

if [ "$EXIT_CODE" -ne 0 ]; then
  ok "exit code non-zero on tampered hash ($EXIT_CODE)"
else
  fail "expected non-zero exit on tampered hash, got 0"
fi

if echo "$OUTPUT" | grep -q "upstream wiki-lint changed since fork"; then
  ok "warning message present"
else
  fail "warning message missing; got: $OUTPUT"
fi

rm -rf "$TMPDIR_TEST"

# --- Test 2: real cache → exit 0 ---
echo ""
echo "Test 2: real cache → should exit 0"

CO="$HOME/.claude/plugins/cache/claude-obsidian-marketplace/claude-obsidian"
if [ ! -d "$CO" ]; then
  echo "  SKIP: upstream cache not installed ($CO)"
else
  OUTPUT2="$(bash "$DRIFT_SCRIPT" --strict 2>&1)" && EXIT_CODE2=0 || EXIT_CODE2=$?
  if [ "$EXIT_CODE2" -eq 0 ]; then
    ok "exit 0 against real (unchanged) cache"
  else
    fail "expected exit 0 against real cache, got $EXIT_CODE2; output: $OUTPUT2"
  fi
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
