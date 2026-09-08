#!/usr/bin/env bash
# Tests for scripts/lib/observability-registry.sh (HIMMEL-1680).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=observability-registry.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/observability-registry.sh"

PASS=0
FAIL=0
TMP_ROOT=""
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT"
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
assert_jq() {
    local name="$1" expression="$2" file="$3"
    if jq -e "$expression" "$file" >/dev/null; then pass "$name"; else fail "$name"; fi
}
summary() {
    echo
    echo "===================================="
    echo "test summary: $PASS passed, $FAIL failed"
    echo "===================================="
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

TMP_ROOT=$(mktemp -d)
export HIMMEL_OBSERVABILITY_CONFIG="$TMP_ROOT/observability.json"

cat > "$HIMMEL_OBSERVABILITY_CONFIG" <<'JSON'
{
  "flows": [
    {
      "name": "graphmap-luna",
      "cadence_seconds": 123,
      "stall_deadline_seconds": 7200
    },
    {
      "name": "keep-flow",
      "cadence_seconds": 60
    }
  ],
  "expected_tasks": [
    "keep-task"
  ],
  "vault_path": "C:/vault",
  "custom": {
    "enabled": true
  }
}
JSON

observability_register_cadence graphmap-luna 86400 HIMMEL-GraphMap-Luna
cp "$HIMMEL_OBSERVABILITY_CONFIG" "$TMP_ROOT/after-first.json"
observability_register_cadence graphmap-luna 86400 HIMMEL-GraphMap-Luna

if cmp -s "$TMP_ROOT/after-first.json" "$HIMMEL_OBSERVABILITY_CONFIG"; then
    pass "second registration is byte-identical"
else
    fail "second registration changed registry bytes"
fi
assert_jq "existing cadence is updated" '.flows[] | select(.name == "graphmap-luna") | .cadence_seconds == 86400' "$HIMMEL_OBSERVABILITY_CONFIG"
assert_jq "existing flow keys are preserved" '.flows[] | select(.name == "graphmap-luna") | .stall_deadline_seconds == 7200' "$HIMMEL_OBSERVABILITY_CONFIG"
assert_jq "unrelated flow is preserved" 'any(.flows[]; .name == "keep-flow")' "$HIMMEL_OBSERVABILITY_CONFIG"
assert_jq "unrelated top-level keys are preserved" '.vault_path == "C:/vault" and .custom.enabled == true' "$HIMMEL_OBSERVABILITY_CONFIG"
assert_jq "task is inserted exactly once" '[.expected_tasks[] | select(. == "HIMMEL-GraphMap-Luna")] | length == 1' "$HIMMEL_OBSERVABILITY_CONFIG"
assert_jq "unrelated task is preserved" 'any(.expected_tasks[]; . == "keep-task")' "$HIMMEL_OBSERVABILITY_CONFIG"

observability_unregister_cadence graphmap-luna HIMMEL-GraphMap-Luna
assert_jq "deliberate removal unregisters the flow" 'all(.flows[]; .name != "graphmap-luna")' "$HIMMEL_OBSERVABILITY_CONFIG"
assert_jq "deliberate removal unregisters the task" 'all(.expected_tasks[]; . != "HIMMEL-GraphMap-Luna")' "$HIMMEL_OBSERVABILITY_CONFIG"
assert_jq "removal preserves unrelated entries" 'any(.flows[]; .name == "keep-flow") and any(.expected_tasks[]; . == "keep-task") and .vault_path == "C:/vault"' "$HIMMEL_OBSERVABILITY_CONFIG"

if [ ! -d "$HIMMEL_OBSERVABILITY_CONFIG.lock" ]; then
    pass "lock dir is released after every call"
else
    fail "lock dir left behind: $HIMMEL_OBSERVABILITY_CONFIG.lock"
fi

summary
