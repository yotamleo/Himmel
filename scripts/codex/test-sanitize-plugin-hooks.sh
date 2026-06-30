#!/usr/bin/env bash
# Hermetic tests for sanitize-plugin-hooks.sh (HIMMEL-651).
# No real Codex install needed: a temp CODEX_HOME holds fixture plugin-cache
# hooks.json files (one WITH a top-level `description`, one already clean, one
# malformed). Asserts the sanitizer strips only the `description` key, preserves
# the `hooks` block, honours --dry-run, is idempotent, leaves clean/malformed
# files untouched, and exits 0 when there is no cache dir.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANITIZER="$SCRIPT_DIR/sanitize-plugin-hooks.sh"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- fixtures ----------------------------------------------------------------
CACHE="$TMP/.codex/plugins/cache"
mkdir -p "$CACHE/ext-desc/hooks" "$CACHE/ext-desc2/hooks" "$CACHE/ext-clean/hooks" "$CACHE/ext-bad/hooks"

# WITH top-level description + a hooks block (the offending shape).
cat > "$CACHE/ext-desc/hooks/hooks.json" <<'JSON'
{
  "description": "External plugin - rejected by Codex",
  "hooks": {
    "SessionStart": [
      { "matcher": "startup", "hooks": [ { "type": "command", "command": "echo hi" } ] }
    ]
  }
}
JSON

# A SECOND file with description (exercises multi-file count aggregation).
cat > "$CACHE/ext-desc2/hooks/hooks.json" <<'JSON'
{
  "description": "another external",
  "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo two" } ] } ] }
}
JSON

# Already clean (no top-level description).
cat > "$CACHE/ext-clean/hooks/hooks.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "echo bye" } ] }
    ]
  }
}
JSON

# Malformed JSON — must be left untouched, never crash the run.
printf '%s' '{ not valid json' > "$CACHE/ext-bad/hooks/hooks.json"
bad_before="$(cat "$CACHE/ext-bad/hooks/hooks.json")"

# --- 1. dry-run reports but mutates nothing -----------------------------------
out="$(CODEX_HOME="$TMP/.codex" bash "$SANITIZER" --dry-run 2>&1)"
echo "$out" | grep -q "WOULD STRIP : .*ext-desc/" || fail "dry-run did not flag ext-desc"
echo "$out" | grep -q "WOULD STRIP : .*ext-desc2/" || fail "dry-run did not flag ext-desc2"
echo "$out" | grep -q "DRY-RUN: 2 of 4" || fail "dry-run count wrong (want 2 of 4): $out"
echo "$out" | grep -q "SKIP (unparseable): .*ext-bad" || fail "dry-run did not report ext-bad as unparseable"
if jq -e 'has("description")' "$CACHE/ext-desc/hooks/hooks.json" >/dev/null 2>&1; then
  pass "dry-run left description in place"
else
  fail "dry-run MUTATED ext-desc"
fi

# --- 2. real run strips description, preserves hooks --------------------------
out="$(CODEX_HOME="$TMP/.codex" bash "$SANITIZER" 2>&1)"
echo "$out" | grep -q "STRIPPED    : .*ext-desc/" || fail "real run did not strip ext-desc"
echo "$out" | grep -q "STRIPPED    : .*ext-desc2/" || fail "real run did not strip ext-desc2"
echo "$out" | grep -q "OK: sanitized 2 of 4" || fail "real-run summary wrong (want 2 of 4): $out"
if jq -e 'has("description")' "$CACHE/ext-desc/hooks/hooks.json" >/dev/null 2>&1; then
  fail "description NOT removed from ext-desc"
else
  pass "description removed from ext-desc"
fi
if jq -e 'has("description")' "$CACHE/ext-desc2/hooks/hooks.json" >/dev/null 2>&1; then
  fail "description NOT removed from ext-desc2"
else
  pass "description removed from ext-desc2"
fi
# hooks block intact (command survives).
got="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CACHE/ext-desc/hooks/hooks.json" 2>/dev/null)"
if [ "$got" = "echo hi" ]; then pass "hooks block preserved after strip"; else fail "hooks block damaged (got '$got')"; fi

# clean file untouched (still parses, still has its command).
got="$(jq -r '.hooks.Stop[0].hooks[0].command' "$CACHE/ext-clean/hooks/hooks.json" 2>/dev/null)"
if [ "$got" = "echo bye" ]; then pass "clean file left intact"; else fail "clean file changed (got '$got')"; fi

# malformed file untouched byte-for-byte.
if [ "$(cat "$CACHE/ext-bad/hooks/hooks.json")" = "$bad_before" ]; then
  pass "malformed file left untouched"
else
  fail "malformed file was mutated"
fi

# --- 3. idempotent re-run -----------------------------------------------------
out="$(CODEX_HOME="$TMP/.codex" bash "$SANITIZER" 2>&1)"
echo "$out" | grep -q "OK: nothing to sanitize" || fail "re-run not idempotent: $out"

# --- 4. no cache dir -> graceful exit 0 ---------------------------------------
empty="$TMP/empty-home"
mkdir -p "$empty"
rc=0
out="$(CODEX_HOME="$empty/.codex" bash "$SANITIZER" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then pass "no-cache exits 0"; else fail "no-cache exit $rc (want 0)"; fi
echo "$out" | grep -q "no Codex plugin cache" || fail "no-cache message missing"

# --- 5. unknown arg rejected (exit 2) -----------------------------------------
rc=0
CODEX_HOME="$TMP/.codex" bash "$SANITIZER" --bogus >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then pass "unknown arg rejected (exit 2)"; else fail "unknown arg exit $rc (want 2)"; fi

echo ""
if [ "$fails" -eq 0 ]; then echo "PASS"; else echo "FAIL ($fails)"; exit 1; fi
