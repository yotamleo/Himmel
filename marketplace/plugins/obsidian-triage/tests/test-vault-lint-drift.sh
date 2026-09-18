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

# HIMMEL-3191: Tests 1-3 must not depend on the live plugin cache under the real
# $HOME (absent on CI, so they used to fail or self-skip there). The fixture is a
# fake HOME holding an upstream cache whose files hash to a fixture UPSTREAM.json,
# next to a copy of the drift script (it locates UPSTREAM.json beside itself).
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
FAKE_HOME="$FIX/home"
CACHE_VER="$FAKE_HOME/.claude/plugins/cache/claude-obsidian-marketplace/claude-obsidian/1.0.0"
FIX_SKILL_DIR="$FIX/skills/vault-lint"
mkdir -p "$CACHE_VER/skills/wiki-lint" "$CACHE_VER/agents" "$FIX_SKILL_DIR"
printf 'fixture upstream wiki-lint skill\n' > "$CACHE_VER/skills/wiki-lint/SKILL.md"
printf 'fixture upstream wiki-lint agent\n' > "$CACHE_VER/agents/wiki-lint.md"
cp "$DRIFT_SCRIPT" "$FIX_SKILL_DIR/check-vendor-drift.sh"

# write_upstream_json <skill-sha> <agent-sha> -> FIX_SKILL_DIR/UPSTREAM.json
write_upstream_json() {
  python -c "
import json, sys
print(json.dumps({'source': 'fixture', 'files': [
  {'path': 'skills/wiki-lint/SKILL.md', 'sha256': sys.argv[1]},
  {'path': 'agents/wiki-lint.md', 'sha256': sys.argv[2]}]}, indent=2))
" "$1" "$2" > "$FIX_SKILL_DIR/UPSTREAM.json"
}
sha256_of() {
  python -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"
}
run_fixture_drift() {
  HOME="$FAKE_HOME" bash "$FIX_SKILL_DIR/check-vendor-drift.sh" "$@" 2>&1
}

GOOD_SKILL_SHA="$(sha256_of "$CACHE_VER/skills/wiki-lint/SKILL.md")"
GOOD_AGENT_SHA="$(sha256_of "$CACHE_VER/agents/wiki-lint.md")"

# --- Test 1: tampered hash → --strict exits non-zero with the warning ---
echo ""
echo "Test 1: tampered UPSTREAM.json → --strict should exit non-zero with warning"

write_upstream_json "$(printf 'deadbeef%.0s' 1 2 3 4 5 6 7 8)" "$GOOD_AGENT_SHA"
OUTPUT="$(run_fixture_drift --strict)" && EXIT_CODE=0 || EXIT_CODE=$?

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

# --- Test 2: matching hashes → exit 0, in sync (hermetic fixture cache) ---
echo ""
echo "Test 2: fixture cache matching UPSTREAM.json → should exit 0, in sync"

write_upstream_json "$GOOD_SKILL_SHA" "$GOOD_AGENT_SHA"
OUTPUT2="$(run_fixture_drift --strict)" && EXIT_CODE2=0 || EXIT_CODE2=$?
if [ "$EXIT_CODE2" -eq 0 ] && echo "$OUTPUT2" | grep -q "in sync with upstream wiki-lint"; then
  ok "exit 0 and 'in sync' against a matching fixture cache"
else
  fail "expected exit 0 + 'in sync', got $EXIT_CODE2; output: $OUTPUT2"
fi

# --- Test 3: the tracked UPSTREAM.json carries the two entries the script reads ---
echo ""
echo "Test 3: tracked UPSTREAM.json lists SKILL.md and wiki-lint.md"

if python -c "
import json, sys
d = json.load(open(sys.argv[1]))
paths = [f['path'] for f in d['files']]
assert any('SKILL.md' in p for p in paths) and any('wiki-lint.md' in p for p in paths)
assert all(len(f['sha256']) == 64 for f in d['files'])
" "$UPSTREAM_JSON"; then
  ok "tracked UPSTREAM.json has both entries with 64-hex hashes"
else
  fail "tracked UPSTREAM.json is missing an entry the drift script reads"
fi

# --- Test 4: real cache → exit 0 (operator-station only: needs the live upstream) ---
echo ""
echo "Test 4: real cache → should exit 0"

CO="$HOME/.claude/plugins/cache/claude-obsidian-marketplace/claude-obsidian"
if [ ! -d "$CO" ]; then
  echo "  SKIP: upstream cache not installed ($CO) — real-upstream drift NOT checked on this host"
else
  OUTPUT4="$(bash "$DRIFT_SCRIPT" --strict 2>&1)" && EXIT_CODE4=0 || EXIT_CODE4=$?
  if [ "$EXIT_CODE4" -eq 0 ]; then
    ok "exit 0 against real (unchanged) cache"
  else
    fail "expected exit 0 against real cache, got $EXIT_CODE4; output: $OUTPUT4"
  fi
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
