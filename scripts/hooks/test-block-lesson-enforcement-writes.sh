#!/usr/bin/env bash
# Smoke suite for scripts/hooks/block-lesson-enforcement-writes.sh (HIMMEL-767
# deliverable 3), the thin PreToolUse wrapper that delegates to
# scripts/guardrails/lesson-write-fence.sh. This is a THIN-WRAPPER smoke test,
# not a re-test of the fence's classification logic (that suite is
# scripts/guardrails/test-lesson-write-fence.sh - do not duplicate it
# here). Covers: env fast-exit, delegate-reaches-fence, fence-missing-while-
# active (opposite polarity from block-graphify-egress), non-matcher tool,
# malformed JSON in both env states.
#
# Hermetic: temp copies only, never the live repo. bash 3.2-safe.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/block-lesson-enforcement-writes.sh"
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }
GUARDRAILS="$HOOKS/../guardrails"
POLICY="$GUARDRAILS/enforcement-paths.json"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cp "$POLICY" "$T/enforcement-paths.json"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# check <label> <block|allow> <json> <hook-path> [ENV=val ...]
check() {
    local label="$1" expect="$2" json="$3" hookpath="$4"; shift 4
    local rc got
    printf '%s' "$json" | env "$@" bash "$hookpath" >/dev/null 2>&1
    rc=$?
    case "$rc" in
        0) got=allow ;;
        2) got=block ;;
        *) got="?(rc=$rc)" ;;
    esac
    if [ "$got" = "$expect" ]; then ok "$label"; else
        bad "$label - expected $expect got $got"; fi
}

echo "== env fast-exit =="
check "inactive + enforcement Write -> allow" allow \
    '{"tool_name":"Write","tool_input":{"file_path":"scripts/guardrails/x.sh"}}' \
    "$HOOK"

echo "== delegate-reaches-fence =="
check "active + enforcement Write -> deny" block \
    '{"tool_name":"Write","tool_input":{"file_path":"scripts/guardrails/x.sh"}}' \
    "$HOOK" HIMMEL_LESSON_LOOP=1 LESSON_FENCE_POLICY="$T/enforcement-paths.json"
check "active + allowed Write -> allow" allow \
    '{"tool_name":"Write","tool_input":{"file_path":"scripts/foo.sh"}}' \
    "$HOOK" HIMMEL_LESSON_LOOP=1 LESSON_FENCE_POLICY="$T/enforcement-paths.json"

echo "== fence-missing-while-active (opposite polarity from block-graphify-egress) =="
mkdir -p "$T/nofence/hooks"
cp "$HOOK" "$T/nofence/hooks/block-lesson-enforcement-writes.sh"
check "active, fence sibling missing -> deny" block \
    '{"tool_name":"Write","tool_input":{"file_path":"scripts/foo.sh"}}' \
    "$T/nofence/hooks/block-lesson-enforcement-writes.sh" HIMMEL_LESSON_LOOP=1

echo "== non-matcher tool =="
check "active + Read -> allow (tool outside matcher set)" allow \
    '{"tool_name":"Read","tool_input":{"file_path":"scripts/guardrails/x.sh"}}' \
    "$HOOK" HIMMEL_LESSON_LOOP=1

echo "== malformed JSON =="
check "active + malformed JSON -> deny (strict, no narrow fallback)" block \
    '{not json' "$HOOK" HIMMEL_LESSON_LOOP=1
check "inactive + malformed JSON -> allow (fast-exit before parse)" allow \
    '{not json' "$HOOK"

echo "== plugin hooks.json fail-closed under stale checkout (round-3 CR fix, HIMMEL-767) =="
HOOKS_JSON="$HOOKS/../../marketplace/plugins/himmel-ops/hooks/hooks.json"
if [ -f "$HOOKS_JSON" ]; then
    PLUGIN_CMD="$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | test("block-lesson-enforcement-writes")) | .hooks[0].command' "$HOOKS_JSON" 2>/dev/null)"
    if [ -n "$PLUGIN_CMD" ]; then
        EMPTY_PROJECT="$(mktemp -d)"
        env CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" HIMMEL_LESSON_LOOP=1 bash -c "$PLUGIN_CMD" >/dev/null 2>&1
        rc_loop=$?
        env CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" bash -c "$PLUGIN_CMD" >/dev/null 2>&1
        rc_normal=$?
        rm -rf "$EMPTY_PROJECT"
        if [ "$rc_loop" -eq 2 ]; then
            ok "plugin command, hook missing + HIMMEL_LESSON_LOOP=1 -> exit 2 (fail closed)"
        else
            bad "plugin command, hook missing + LOOP=1 - expected exit 2 got $rc_loop"
        fi
        if [ "$rc_normal" -eq 0 ]; then
            ok "plugin command, hook missing + LOOP unset -> exit 0 (normal session no-op)"
        else
            bad "plugin command, hook missing + LOOP unset - expected exit 0 got $rc_normal"
        fi
    else
        bad "plugin hooks.json: could not extract block-lesson-enforcement-writes command via jq"
    fi
else
    printf '  SKIP  plugin hooks.json test (file not found: %s)\n' "$HOOKS_JSON"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
