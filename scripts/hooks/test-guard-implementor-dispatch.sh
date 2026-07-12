#!/usr/bin/env bash
# Tests for scripts/hooks/guard-implementor-dispatch.sh (HIMMEL-920). Hermetic.
#
# Usage: bash scripts/hooks/test-guard-implementor-dispatch.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-implementor-dispatch.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "ok   $label (rc=$actual)"
        pass=$((pass + 1))
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        echo "ok   $label (contains '$needle')"
        pass=$((pass + 1))
    else
        echo "FAIL $label — did not contain '$needle'"
        echo "  actual: $haystack"
        fail=$((fail + 1))
    fi
}

assert_empty() {
    local label="$1" actual="$2"
    if [ -z "$actual" ]; then
        echo "ok   $label (empty)"
        pass=$((pass + 1))
    else
        echo "FAIL $label — expected empty, got: $actual"
        fail=$((fail + 1))
    fi
}

# payload_full <subagent_type> <model> <prompt> — all three fields present.
payload_full() {
    jq -n --arg st "$1" --arg m "$2" --arg p "$3" \
        '{"tool_name":"Agent","tool_input":{"subagent_type":$st,"model":$m,"prompt":$p}}'
}

# payload_no_model <subagent_type> <prompt> — model key OMITTED entirely.
payload_no_model() {
    jq -n --arg st "$1" --arg p "$2" \
        '{"tool_name":"Agent","tool_input":{"subagent_type":$st,"prompt":$p}}'
}

# mkcache <path> <utilization-literal>
mkcache() {
    # resets_at = a FUTURE epoch (live window) — the guard treats an expired
    # window as UNKNOWN (see T14), so deny/warn fixtures must stay live.
    printf '{"five_hour":{"utilization":%s,"resets_at":"%s"}}' "$2" "$(( $(date +%s) + 3600 ))" > "$1"
}

# run_hook <name> <json> [env KEY=VAL ...] — writes stdout/stderr to
# $TMP/out-<name> / $TMP/err-<name>, returns rc via echo.
run_hook() {
    local name="$1" json="$2"; shift 2
    printf '%s' "$json" | env "$@" bash "$HOOK" >"$TMP/out-$name" 2>"$TMP/err-$name"
    echo "$?"
}

echo "=== guard-implementor-dispatch smoke tests ==="

# T1: Impl-shaped general-purpose+sonnet, util=85 → rc=2, stderr names glm-subagent.
CACHE1="$TMP/cache1.json"; mkcache "$CACHE1" 85
RC1=$(run_hook t1 "$(payload_full general-purpose sonnet 'please implement the fix for the failing test')" \
    IMPL_GUARD_CACHE_PATH="$CACHE1")
assert_rc "T1 hard-deny rc" 2 "$RC1"
assert_contains "T1 stderr names glm-subagent" "glm-subagent" "$(cat "$TMP/err-t1")"

# T2: Reviewer dispatch (pr-review-toolkit:code-reviewer), reviewer-shaped prompt,
# util=85 → allow, silent (prompt classifier rejects before the bank check runs).
CACHE2="$TMP/cache2.json"; mkcache "$CACHE2" 85
RC2=$(run_hook t2 "$(payload_full pr-review-toolkit:code-reviewer sonnet 'review this PR for quality issues and report findings')" \
    IMPL_GUARD_CACHE_PATH="$CACHE2")
assert_rc "T2 reviewer dispatch rc" 0 "$RC2"
assert_empty "T2 reviewer dispatch stdout" "$(cat "$TMP/out-t2")"

# T3: Impl-shaped, util=70 → allow + permissionDecisionReason advisory JSON.
CACHE3="$TMP/cache3.json"; mkcache "$CACHE3" 70
RC3=$(run_hook t3 "$(payload_full general-purpose sonnet 'implement the fix')" \
    IMPL_GUARD_CACHE_PATH="$CACHE3")
assert_rc "T3 warn-tier rc" 0 "$RC3"
assert_contains "T3 warn-tier advisory JSON" "permissionDecisionReason" "$(cat "$TMP/out-t3")"

# T4: Impl-shaped, util=20 → allow, silent.
CACHE4="$TMP/cache4.json"; mkcache "$CACHE4" 20
RC4=$(run_hook t4 "$(payload_full general-purpose sonnet 'implement the fix')" \
    IMPL_GUARD_CACHE_PATH="$CACHE4")
assert_rc "T4 low-util rc" 0 "$RC4"
assert_empty "T4 low-util stdout" "$(cat "$TMP/out-t4")"

# T5: Missing cache → allow + WARN.
RC5=$(run_hook t5 "$(payload_full general-purpose sonnet 'implement the fix')" \
    IMPL_GUARD_CACHE_PATH="$TMP/does-not-exist.json")
assert_rc "T5 missing-cache rc" 0 "$RC5"
assert_contains "T5 missing-cache stderr WARN" "cache not found" "$(cat "$TMP/err-t5")"

# T6: Stale cache (touch -t, >300s) → allow + WARN.
CACHE6="$TMP/cache6.json"; mkcache "$CACHE6" 85
touch -d "1 hour ago" "$CACHE6" 2>/dev/null \
    || touch -t "$(date -v -1H +%Y%m%d%H%M.%S 2>/dev/null)" "$CACHE6" 2>/dev/null \
    || true
RC6=$(run_hook t6 "$(payload_full general-purpose sonnet 'implement the fix')" \
    IMPL_GUARD_CACHE_PATH="$CACHE6")
assert_rc "T6 stale-cache rc" 0 "$RC6"
assert_contains "T6 stale-cache stderr WARN" "stale" "$(cat "$TMP/err-t6")"

# T7: IMPL_GUARD_OK=1, util=85 → allow, silent (bypass short-circuits before parsing).
CACHE7="$TMP/cache7.json"; mkcache "$CACHE7" 85
RC7=$(run_hook t7 "$(payload_full general-purpose sonnet 'implement the fix')" \
    IMPL_GUARD_CACHE_PATH="$CACHE7" IMPL_GUARD_OK=1)
assert_rc "T7 IMPL_GUARD_OK bypass rc" 0 "$RC7"
assert_empty "T7 IMPL_GUARD_OK bypass stdout" "$(cat "$TMP/out-t7")"

# T7b: IMPL_GUARD_DISABLE=1 → allow, silent.
RC7B=$(run_hook t7b "$(payload_full general-purpose sonnet 'implement the fix')" \
    IMPL_GUARD_CACHE_PATH="$CACHE7" IMPL_GUARD_DISABLE=1)
assert_rc "T7b IMPL_GUARD_DISABLE bypass rc" 0 "$RC7B"
assert_empty "T7b IMPL_GUARD_DISABLE bypass stdout" "$(cat "$TMP/out-t7b")"

# T8: Absent model + impl prompt, util=85 → deny per HIMMEL-972.
CACHE8="$TMP/cache8.json"; mkcache "$CACHE8" 85
RC8=$(run_hook t8 "$(payload_no_model general-purpose 'implement the fix')" \
    IMPL_GUARD_CACHE_PATH="$CACHE8")
assert_rc "T8 absent-model rc" 2 "$RC8"
assert_contains "T8 absent-model deny stderr" "glm-subagent" "$(cat "$TMP/err-t8")"

# T8b: Absent model + impl prompt, util=70 → allow + advisory (WARN tier).
CACHE8B="$TMP/cache8b.json"; mkcache "$CACHE8B" 70
RC8B=$(run_hook t8b "$(payload_no_model general-purpose 'implement the fix')" \
    IMPL_GUARD_CACHE_PATH="$CACHE8B")
assert_rc "T8b absent-model WARN rc" 0 "$RC8B"
assert_contains "T8b absent-model allow decision" '"permissionDecision":"allow"' "$(cat "$TMP/out-t8b")"
assert_contains "T8b absent-model advisory JSON" "permissionDecisionReason" "$(cat "$TMP/out-t8b")"

# T8c: Absent model + non-allow-listed subagent, util=85 → WARN, never deny.
CACHE8C="$TMP/cache8c.json"; mkcache "$CACHE8C" 85
RC8C=$(run_hook t8c "$(payload_no_model caveman:cavecrew-builder 'implement the fix')" \
    IMPL_GUARD_CACHE_PATH="$CACHE8C")
assert_rc "T8c absent-model non-allow-listed rc" 0 "$RC8C"
assert_contains "T8c absent-model allow decision" '"permissionDecision":"allow"' "$(cat "$TMP/out-t8c")"
assert_contains "T8c absent-model advisory JSON" "permissionDecisionReason" "$(cat "$TMP/out-t8c")"

# T9: Haiku impl dispatch, util=85 → allow, silent.
CACHE9="$TMP/cache9.json"; mkcache "$CACHE9" 85
RC9=$(run_hook t9 "$(payload_full general-purpose haiku 'implement the fix')" \
    IMPL_GUARD_CACHE_PATH="$CACHE9")
assert_rc "T9 haiku rc" 0 "$RC9"
assert_empty "T9 haiku stdout" "$(cat "$TMP/out-t9")"

# T10: Malformed JSON → allow.
RC10=$(run_hook t10 'not-json{{{')
assert_rc "T10a malformed-JSON rc" 0 "$RC10"

# T10b: missing jq (empty PATH; hook exits before touching stdin/other binaries).
BASH_ABS=$(command -v bash)
EMPTY_DIR="$TMP/empty-path"
mkdir -p "$EMPTY_DIR"
printf '%s' "$(payload_full general-purpose sonnet 'implement the fix')" \
    | env PATH="$EMPTY_DIR" "$BASH_ABS" "$HOOK" >"$TMP/out-t10b" 2>"$TMP/err-t10b"
RC10B=$?
assert_rc "T10b missing-jq rc" 0 "$RC10B"

# T11: Float utilization "84.5" → correct numeric compare (rc=2 at HARD=80).
CACHE11="$TMP/cache11.json"; mkcache "$CACHE11" 84.5
RC11=$(run_hook t11 "$(payload_full general-purpose sonnet 'implement the fix')" \
    IMPL_GUARD_CACHE_PATH="$CACHE11")
assert_rc "T11 float-util hard-deny rc" 2 "$RC11"

# T12: Leaked-epoch utilization (1783836000) → clamped → UNKNOWN → allow + WARN.
CACHE12="$TMP/cache12.json"; mkcache "$CACHE12" 1783836000
RC12=$(run_hook t12 "$(payload_full general-purpose sonnet 'implement the fix')" \
    IMPL_GUARD_CACHE_PATH="$CACHE12")
assert_rc "T12 leaked-epoch rc" 0 "$RC12"
assert_contains "T12 leaked-epoch stderr WARN" "unusable" "$(cat "$TMP/err-t12")"

# T13: Prompt containing "dispatch" but no marker → allow (the `patch` substring
# FP — "dispatch" contains "patch" — is dead because `patch` was dropped).
CACHE13="$TMP/cache13.json"; mkcache "$CACHE13" 85
RC13=$(run_hook t13 "$(payload_full general-purpose sonnet 'dispatch this task to the subagent')" \
    IMPL_GUARD_CACHE_PATH="$CACHE13")
assert_rc "T13 dispatch-no-marker rc" 0 "$RC13"
assert_empty "T13 dispatch-no-marker stdout" "$(cat "$TMP/out-t13")"

# T14: expired five_hour window (resets_at in the past) → the value predates
# a bank reset (the producer preserves stale five_hour under a fresh mtime on
# seven_day-only payloads) → UNKNOWN → allow + WARN, never a spurious DENY.
CACHE14="$TMP/cache14.json"
printf '{"five_hour":{"utilization":%s,"resets_at":"%s"}}' 85 "$(( $(date +%s) - 100 ))" > "$CACHE14"
RC14=$(run_hook t14 "$(payload_full general-purpose sonnet 'implement the fix')"     IMPL_GUARD_CACHE_PATH="$CACHE14")
assert_rc "T14 expired-window rc (allow)" 0 "$RC14"
assert_contains "T14 expired-window WARN" "window expired" "$(cat "$TMP/err-t14")"

# T15/T16 (codex-adv round 2): realistic CR-fix dispatch wording — the exact
# s40 pattern this guard exists for — must classify as impl-shaped.
CACHE15="$TMP/cache15.json"; mkcache "$CACHE15" 85
RC15=$(run_hook t15 "$(payload_full general-purpose sonnet 'address the CodeRabbit comments on this PR and push')"     IMPL_GUARD_CACHE_PATH="$CACHE15")
assert_rc "T15 address-coderabbit-comments rc (deny)" 2 "$RC15"
RC16=$(run_hook t16 "$(payload_full general-purpose sonnet 'resolve all review findings from the panel')"     IMPL_GUARD_CACHE_PATH="$CACHE15")
assert_rc "T16 resolve-review-findings rc (deny)" 2 "$RC16"

# T17/T18 (codex-adv r3): HARD deny requires a provably-live window.
# Absent resets_at -> downgrade to the advisory JSON (never a false block);
# a fractional-second ISO future resets_at parses and still denies.
CACHE17="$TMP/cache17.json"
printf '{"five_hour":{"utilization":85}}' > "$CACHE17"
RC17=$(run_hook t17 "$(payload_full general-purpose sonnet 'implement the fix')"     IMPL_GUARD_CACHE_PATH="$CACHE17")
assert_rc "T17 no-resets_at at HARD rc (allow, downgraded)" 0 "$RC17"
assert_contains "T17 downgraded advisory JSON" "permissionDecisionReason" "$(cat "$TMP/out-t17")"
CACHE18="$TMP/cache18.json"
printf '{"five_hour":{"utilization":85,"resets_at":"%s"}}' "$(date -u -d "@$(( $(date +%s) + 3600 ))" '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || python3 -c "import datetime,time;print(datetime.datetime.utcfromtimestamp(time.time()+3600).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")" > "$CACHE18"
RC18=$(run_hook t18 "$(payload_full general-purpose sonnet 'implement the fix')"     IMPL_GUARD_CACHE_PATH="$CACHE18")
assert_rc "T18 fractional-ISO future resets_at rc (deny)" 2 "$RC18"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
