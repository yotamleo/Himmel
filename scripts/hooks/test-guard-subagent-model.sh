#!/usr/bin/env bash
# Tests for guard-subagent-model.sh (HIMMEL-2653): every trip/no-trip shape,
# both the default WARN action and the HIMMEL_REQUIRE_SUBAGENT_MODEL=1 DENY
# escalation, the SUBAGENT_MODEL_OK=1 escape hatch, and fail-open on
# malformed input.
#
# Usage: bash scripts/hooks/test-guard-subagent-model.sh
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure bash + jq over a temp sandbox; NOT ported to native PowerShell. A test
# harness needs no .ps1 twin (project convention: a documented platform guard
# suffices for a test fixture) — it exercises the bash hook above, so it runs
# wherever that hook runs.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline; see test-guard-implementor-dispatch.sh's identical helper for the
# SIGPIPE-under-pipefail rationale (HIMMEL-1430).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-subagent-model.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

# Resolve bash ONCE from the suite's own unmodified PATH, before the
# missing-jq case hands `env` a narrowed one — an env-relative "bash" would
# otherwise be resolved through the NARROWED PATH it is about to test with,
# which can make bash itself unfindable (127) rather than exercising the
# hook's own jq-missing fail-open path. Same lesson as
# test-guard-implementor-dispatch.sh's BASH_ABS (HIMMEL-1567).
BASH_ABS=$(command -v bash)
[ -n "$BASH_ABS" ] || { echo "FATAL: cannot resolve bash on PATH" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-subagent-model-guard.XXXXXX")"
[ -n "$TMP" ] || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "ok   $label (rc=$actual)"
        pass=$((pass + 1))
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F "$needle"; then
        echo "ok   $label"
        pass=$((pass + 1))
    else
        echo "FAIL $label — missing '$needle'"
        echo "  actual: $haystack"
        fail=$((fail + 1))
    fi
}

assert_empty() {
    local label="$1" actual="$2"
    if [ -z "$actual" ]; then
        echo "ok   $label"
        pass=$((pass + 1))
    else
        echo "FAIL $label — expected empty, got: $actual"
        fail=$((fail + 1))
    fi
}

payload() {
    # payload <subagent_type> <model>  (either may be empty string)
    jq -nc --arg st "$1" --arg m "$2" \
        '{tool_name:"Agent",session_id:"sess-test",tool_input:{subagent_type:$st,description:"d",prompt:"p",model:$m}}'
}

payload_no_model_field() {
    jq -nc --arg st "$1" \
        '{tool_name:"Agent",session_id:"sess-test",tool_input:{subagent_type:$st,description:"d",prompt:"p"}}'
}

payload_no_subagent_field() {
    jq -nc --arg m "$1" \
        '{tool_name:"Agent",session_id:"sess-test",tool_input:{description:"d",prompt:"p",model:$m}}'
}

run_hook() {
    local name="$1" json="$2"; shift 2
    # HIMMEL-2653: env without -i inherits the operator's ambient environment.
    # Pin both knobs the hook reads to their off baseline BEFORE "$@" so an
    # operator's exported SUBAGENT_MODEL_OK=1 or HIMMEL_REQUIRE_SUBAGENT_MODEL=1
    # can never leak into a case that doesn't ask for it -- env applies
    # repeated assignments in order, so a call-site override in "$@" still wins.
    printf '%s' "$json" | env SUBAGENT_MODEL_OK=0 HIMMEL_REQUIRE_SUBAGENT_MODEL=0 "$@" "$BASH_ABS" "$HOOK" >"$TMP/out-$name" 2>"$TMP/err-$name"
    echo "$?"
}

combined_output() {
    cat "$TMP/out-$1" "$TMP/err-$1" 2>/dev/null
}

echo "=== trip cases: general-purpose / no subagent_type, no model ==="

RC1=$(run_hook gp-no-model "$(payload general-purpose '')")
assert_rc "general-purpose with empty model warns (rc=0)" 0 "$RC1"
assert_contains "warn emits visible allow decision" '"permissionDecision":"allow"' "$(cat "$TMP/out-gp-no-model")"
assert_contains "warn names general-purpose" "general-purpose" "$(cat "$TMP/out-gp-no-model")"

RC1B=$(run_hook gp-no-model-field "$(payload_no_model_field general-purpose)")
assert_rc "general-purpose with model field entirely absent warns (rc=0)" 0 "$RC1B"
assert_contains "warn (no model field) emits visible allow decision" '"permissionDecision":"allow"' "$(cat "$TMP/out-gp-no-model-field")"

RC1C=$(run_hook gp-whitespace-model "$(payload general-purpose '   ')")
assert_rc "general-purpose with whitespace-only model warns (rc=0)" 0 "$RC1C"
assert_contains "whitespace model treated as absent" '"permissionDecision":"allow"' "$(cat "$TMP/out-gp-whitespace-model")"

RC1D=$(run_hook no-subagent-no-model "$(payload_no_subagent_field '')")
assert_rc "no subagent_type + no model warns (rc=0)" 0 "$RC1D"
assert_contains "absent subagent_type warns too" '"permissionDecision":"allow"' "$(cat "$TMP/out-no-subagent-no-model")"

echo ""
echo "=== HIMMEL_REQUIRE_SUBAGENT_MODEL=1 escalates to DENY ==="

RC2=$(run_hook gp-no-model-deny "$(payload general-purpose '')" HIMMEL_REQUIRE_SUBAGENT_MODEL=1)
assert_rc "general-purpose with no model DENIES under enforcement" 2 "$RC2"
assert_contains "deny names general-purpose" "general-purpose" "$(cat "$TMP/err-gp-no-model-deny")"
assert_contains "deny tells the operator to pass a model" "explicit model" "$(cat "$TMP/err-gp-no-model-deny")"
assert_contains "deny points at /lanes" "/lanes" "$(cat "$TMP/err-gp-no-model-deny")"

echo ""
echo "=== no-trip cases ==="

RC3=$(run_hook gp-with-model "$(payload general-purpose sonnet)")
assert_rc "general-purpose WITH a model is silent (rc=0)" 0 "$RC3"
assert_empty "general-purpose with model: no output" "$(combined_output gp-with-model)"

RC4=$(run_hook specialist-no-model "$(payload Explore '')")
assert_rc "named specialist type with no model is silent (rc=0)" 0 "$RC4"
assert_empty "named specialist: no output" "$(combined_output specialist-no-model)"

RC4B=$(run_hook specialist-no-model-deny "$(payload Explore '')" HIMMEL_REQUIRE_SUBAGENT_MODEL=1)
assert_rc "named specialist type with no model is silent even under enforcement (rc=0)" 0 "$RC4B"
assert_empty "named specialist under enforcement: no output" "$(combined_output specialist-no-model-deny)"

echo ""
echo "=== escape hatch ==="

RC5=$(run_hook override "$(payload general-purpose '')" SUBAGENT_MODEL_OK=1)
assert_rc "SUBAGENT_MODEL_OK=1 silences the WARN (rc=0)" 0 "$RC5"
assert_empty "override: no stdout" "$(cat "$TMP/out-override")"
assert_contains "override warns about the override itself" "SUBAGENT_MODEL_OK=1" "$(cat "$TMP/err-override")"

RC6=$(run_hook override-deny "$(payload general-purpose '')" SUBAGENT_MODEL_OK=1 HIMMEL_REQUIRE_SUBAGENT_MODEL=1)
assert_rc "SUBAGENT_MODEL_OK=1 silences the DENY too (rc=0)" 0 "$RC6"
assert_empty "override-deny: no stdout" "$(cat "$TMP/out-override-deny")"

echo ""
echo "=== fail-open on malformed / non-Agent input ==="

RC7=$(run_hook malformed "not-json{{{")
assert_rc "malformed input allows (rc=0)" 0 "$RC7"
assert_empty "malformed input: silent" "$(combined_output malformed)"

RC8=$(run_hook empty-input "")
assert_rc "empty stdin allows (rc=0)" 0 "$RC8"
assert_empty "empty stdin: silent" "$(combined_output empty-input)"

NON_AGENT=$(jq -nc '{tool_name:"Bash",session_id:"s",tool_input:{command:"ls"}}')
RC9=$(run_hook non-agent "$NON_AGENT")
assert_rc "non-Agent tool_name allows (rc=0)" 0 "$RC9"
assert_empty "non-Agent tool_name: silent" "$(combined_output non-agent)"

NO_TOOL_INPUT=$(jq -nc '{tool_name:"Agent",session_id:"s"}')
RC10=$(run_hook no-tool-input "$NO_TOOL_INPUT")
assert_rc "missing tool_input allows (rc=0)" 0 "$RC10"
assert_empty "missing tool_input: silent" "$(combined_output no-tool-input)"

echo ""
echo "=== HIMMEL-2653: malformed tool_input fails open, not DENY ==="
# RED control: against the pre-fix hook, .tool_input.model on a payload with
# NO tool_input collapses (via `select(type == "string") // empty`) to the
# same empty string as a genuinely-omitted model — so the hook TRIPS and,
# under enforcement, DENIES a payload its own header promises to fail open
# on. This is the headline regression check: it must exit 0 and stay silent
# even with HIMMEL_REQUIRE_SUBAGENT_MODEL=1 set.
RC10B=$(run_hook no-tool-input-deny "$NO_TOOL_INPUT" HIMMEL_REQUIRE_SUBAGENT_MODEL=1)
assert_rc "missing tool_input allows even under enforcement (rc=0)" 0 "$RC10B"
assert_empty "missing tool_input under enforcement: silent" "$(combined_output no-tool-input-deny)"

TOOL_INPUT_NOT_OBJECT=$(jq -nc '{tool_name:"Agent",session_id:"s",tool_input:"nope"}')
RC10C=$(run_hook tool-input-not-object "$TOOL_INPUT_NOT_OBJECT")
assert_rc "non-object tool_input allows (rc=0)" 0 "$RC10C"
assert_empty "non-object tool_input: silent" "$(combined_output tool-input-not-object)"

RC10D=$(run_hook tool-input-not-object-deny "$TOOL_INPUT_NOT_OBJECT" HIMMEL_REQUIRE_SUBAGENT_MODEL=1)
assert_rc "non-object tool_input allows even under enforcement (rc=0)" 0 "$RC10D"
assert_empty "non-object tool_input under enforcement: silent" "$(combined_output tool-input-not-object-deny)"

MODEL_NOT_STRING=$(jq -nc '{tool_name:"Agent",session_id:"s",tool_input:{subagent_type:"general-purpose",model:123}}')
RC10E=$(run_hook model-not-string "$MODEL_NOT_STRING")
assert_rc "non-string model allows (rc=0)" 0 "$RC10E"
assert_empty "non-string model: silent" "$(combined_output model-not-string)"

RC10F=$(run_hook model-not-string-deny "$MODEL_NOT_STRING" HIMMEL_REQUIRE_SUBAGENT_MODEL=1)
assert_rc "non-string model allows even under enforcement (rc=0)" 0 "$RC10F"
assert_empty "non-string model under enforcement: silent" "$(combined_output model-not-string-deny)"

GENUINE_TRIP=$(jq -nc '{tool_name:"Agent",session_id:"s",tool_input:{subagent_type:"general-purpose"}}')
RC10G=$(run_hook genuine-trip-warn "$GENUINE_TRIP")
assert_rc "genuine trip (real object, omitted model) still warns (rc=0)" 0 "$RC10G"
assert_contains "genuine trip still emits visible allow decision" '"permissionDecision":"allow"' "$(cat "$TMP/out-genuine-trip-warn")"

RC10H=$(run_hook genuine-trip-deny "$GENUINE_TRIP" HIMMEL_REQUIRE_SUBAGENT_MODEL=1)
assert_rc "genuine trip still DENIES under enforcement (rc=2)" 2 "$RC10H"

EMPTY_DIR="$TMP/empty-path"
mkdir -p "$EMPTY_DIR"
# Symlink in the real `cat` so the hook's `input=$(cat ...)` still reads the
# payload — an EMPTY_DIR with no `cat` either would make stdin read empty and
# trip the hook's earlier empty-input check instead, passing this assertion
# for the wrong reason without ever exercising the jq-missing fail-open path.
CAT_ABS=$(command -v cat)
[ -n "$CAT_ABS" ] || { echo "FATAL: cannot resolve cat on PATH" >&2; exit 1; }
ln -s "$CAT_ABS" "$EMPTY_DIR/cat"
RC11=$(run_hook no-jq "$(payload general-purpose '')" PATH="$EMPTY_DIR")
assert_rc "missing jq allows (rc=0)" 0 "$RC11"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
