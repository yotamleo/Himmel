#!/usr/bin/env bash
# Suite for scripts/observability/tool-call-census.sh (HIMMEL-1462).
#
# Synthetic transcripts only — never a copy of a real one. Every fixture below
# is hand-written to the shape the extractor documents, so the suite pins OUR
# contract (row shape, counts, denial classes, dedup, --since/--project
# filtering) and not Claude Code's transcript format.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/tool-call-census.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "expected '$want', got '$got'"; fi
}
summary() {
    echo
    echo "===================================="
    echo "test summary: $PASS passed, $FAIL failed"
    echo "===================================="
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available"
    exit 0
fi

# The fixtures below carry FIXED dates, so census retention must not silently
# prune them once the calendar moves past the window. Section 4c re-enables a
# real window explicitly for the rows it dates relative to NOW.
export HIMMEL_TOOL_CENSUS_RETAIN_DAYS=36500

TMP_ROOT=$(mktemp -d)
PROJECTS="$TMP_ROOT/projects"
SLUG="test--census-project"
OTHER_SLUG="test--other-project"
mkdir -p "$PROJECTS/$SLUG" "$PROJECTS/$OTHER_SLUG"
OUT="$TMP_ROOT/tool-call-census.jsonl"

SESSION_A="$PROJECTS/$SLUG/11111111-aaaa-bbbb-cccc-000000000001.jsonl"
SESSION_B="$PROJECTS/$SLUG/22222222-aaaa-bbbb-cccc-000000000002.jsonl"
SESSION_OTHER="$PROJECTS/$OTHER_SLUG/33333333-aaaa-bbbb-cccc-000000000003.jsonl"

# Session A: two Bash calls (one denied by a PreToolUse hook) plus one MCP call.
cat > "$SESSION_A" <<'JSONL'
{"type":"summary","summary":"no timestamp, no content — must be ignored"}
{"type":"assistant","timestamp":"2026-08-20T10:00:00.000Z","message":{"content":[{"type":"text","text":"working"},{"type":"tool_use","id":"toolu_a1","name":"Bash","input":{}}]}}
{"type":"user","timestamp":"2026-08-20T10:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_a1","is_error":false,"content":"ok"}]}}
{"type":"assistant","timestamp":"2026-08-20T10:00:02.000Z","message":{"content":[{"type":"tool_use","id":"toolu_a2","name":"Bash","input":{}}]}}
{"type":"user","timestamp":"2026-08-20T10:00:03.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_a2","is_error":true,"content":[{"type":"text","text":"PreToolUse:Bash hook error: [bash $CLAUDE_PROJECT_DIR/scripts/hooks/block-read-secrets.sh]: block-read-secrets: refusing Bash command that reads a secret file:\nsecond line"}]}]}}
{"type":"assistant","timestamp":"2026-08-20T10:00:04.000Z","message":{"content":[{"type":"tool_use","id":"toolu_a3","name":"mcp__qmd__query","input":{}}]}}
{"type":"user","timestamp":"2026-08-20T10:00:05.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_a3","is_error":false,"content":"hit"}]}}
JSONL

# Session B: one clean Read, plus a non-denial error on an unrelated tool.
cat > "$SESSION_B" <<'JSONL'
{"type":"assistant","timestamp":"2026-08-20T11:00:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_b1","name":"Read","input":{}}]}}
{"type":"user","timestamp":"2026-08-20T11:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_b1","is_error":false,"content":"file"}]}}
{"type":"assistant","timestamp":"2026-08-20T11:00:02.000Z","message":{"content":[{"type":"tool_use","id":"toolu_b2","name":"Grep","input":{}}]}}
{"type":"user","timestamp":"2026-08-20T11:00:03.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_b2","is_error":true,"content":"Exit code 1"}]}}
{"type":"assistant","timestamp":"2026-08-20T11:00:04.000Z","message":{"content":[{"type":"tool_use","id":"toolu_b3","name":"Write","input":{}}]}}
{"type":"user","timestamp":"2026-08-20T11:00:05.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_b3","is_error":true,"content":"conflict: another session published a newer version, so the write was blocked."}]}}
JSONL

cat > "$SESSION_OTHER" <<'JSONL'
{"type":"assistant","timestamp":"2026-08-20T12:00:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_c1","name":"Bash","input":{}}]}}
JSONL

run_census() { bash "$SCRIPT" --projects-dir "$PROJECTS" --out "$OUT" "$@"; }
row_for() { jq -c --arg s "$1" 'select(.session_id == $s)' "$OUT"; }

echo "=== 1. row shape + counts ==="
run_census --project "$SLUG" >/dev/null
assert_eq "two sessions produce two rows" "2" "$(wc -l < "$OUT" | tr -d ' ')"

A=$(row_for "11111111-aaaa-bbbb-cccc-000000000001")
assert_eq "session A project" "$SLUG" "$(jq -r '.project' <<< "$A")"
assert_eq "session A started_at" "2026-08-20T10:00:00.000Z" "$(jq -r '.started_at' <<< "$A")"
assert_eq "session A ended_at" "2026-08-20T10:00:05.000Z" "$(jq -r '.ended_at' <<< "$A")"
assert_eq "session A total_calls" "3" "$(jq -r '.total_calls' <<< "$A")"
assert_eq "session A total_errors" "1" "$(jq -r '.total_errors' <<< "$A")"
assert_eq "session A Bash calls" "2" "$(jq -r '.tool_calls.Bash.calls' <<< "$A")"
assert_eq "session A Bash errors" "1" "$(jq -r '.tool_calls.Bash.errors' <<< "$A")"
assert_eq "session A MCP tool counted under its namespaced name" "1" \
    "$(jq -r '.tool_calls["mcp__qmd__query"].calls' <<< "$A")"
assert_eq "session A MCP tool has no errors" "0" \
    "$(jq -r '.tool_calls["mcp__qmd__query"].errors' <<< "$A")"
assert_eq "denial classified from the hook name" "1" \
    "$(jq -r '.denials["block-read-secrets"]' <<< "$A")"

B=$(row_for "22222222-aaaa-bbbb-cccc-000000000002")
assert_eq "session B total_calls" "3" "$(jq -r '.total_calls' <<< "$B")"
assert_eq "session B Grep error counted" "1" "$(jq -r '.tool_calls.Grep.errors' <<< "$B")"
# `Exit code 1` has no token at all; `conflict: ... blocked` has a single-word
# one. Neither is a hook name, so neither may become a denial class.
assert_eq "a plain tool failure is an error, not a denial" "0" "$(jq -r '.denials | length' <<< "$B")"
assert_eq "session B counts both failures as errors" "2" "$(jq -r '.total_errors' <<< "$B")"

echo "=== 2. --project scopes the scan ==="
assert_eq "other project excluded" "" "$(row_for "33333333-aaaa-bbbb-cccc-000000000003")"

echo "=== 3. denial classes beyond the PreToolUse shape ==="
CLASS_SESSION="$PROJECTS/$OTHER_SLUG/44444444-aaaa-bbbb-cccc-000000000004.jsonl"
cat > "$CLASS_SESSION" <<'JSONL'
{"type":"assistant","timestamp":"2026-08-20T13:00:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_d1","name":"Bash","input":{}},{"type":"tool_use","id":"toolu_d2","name":"Bash","input":{}},{"type":"tool_use","id":"toolu_d3","name":"PowerShell","input":{}}]}}
{"type":"user","timestamp":"2026-08-20T13:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_d1","is_error":true,"content":"Permission for this action was denied by the Claude Code auto mode classifier. Reason: Blocked by classifier."}]}}
{"type":"user","timestamp":"2026-08-20T13:00:02.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_d2","is_error":true,"content":"The user doesn't want to proceed with this tool use. The tool use was rejected."}]}}
{"type":"user","timestamp":"2026-08-20T13:00:03.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_d3","is_error":true,"content":"cadence-deny-powershell: refusing the PowerShell tool under a cadence leg."}]}}
{"type":"assistant","timestamp":"2026-08-20T13:00:04.000Z","message":{"content":[{"type":"tool_use","id":"toolu_d4","name":"mcp__qmd__query","input":{}}]}}
{"type":"user","timestamp":"2026-08-20T13:00:05.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_d4","is_error":true,"content":"PreToolUse:mcp__qmd__query hook error: [bash $CLAUDE_PROJECT_DIR/scripts/hooks/block-backend-tier.sh]: block-backend-tier: refusing an MCP call the CLI already covers."}]}}
JSONL
D=$(bash "$SCRIPT" --projects-dir "$PROJECTS" --project "$OTHER_SLUG" --stdout 2>/dev/null \
    | jq -c 'select(.session_id == "44444444-aaaa-bbbb-cccc-000000000004")')
assert_eq "auto-mode classifier denial" "1" "$(jq -r '.denials["auto-mode-classifier"]' <<< "$D")"
assert_eq "operator rejection denial" "1" "$(jq -r '.denials["user-rejected"]' <<< "$D")"
assert_eq "leading-token hook denial" "1" "$(jq -r '.denials["cadence-deny-powershell"]' <<< "$D")"
assert_eq "denial on a namespaced MCP tool is classified" "1" \
    "$(jq -r '.denials["block-backend-tier"]' <<< "$D")"

echo "=== 3b. subagent transcripts keep their parent project ==="
mkdir -p "$PROJECTS/$OTHER_SLUG/44444444-aaaa-bbbb-cccc-000000000004/subagents"
cat > "$PROJECTS/$OTHER_SLUG/44444444-aaaa-bbbb-cccc-000000000004/subagents/agent-deadbeef.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-08-20T13:01:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_e1","name":"Read","input":{}}]}}
JSONL
SUB=$(bash "$SCRIPT" --projects-dir "$PROJECTS" --project "$OTHER_SLUG" --stdout 2>/dev/null \
    | jq -c 'select(.session_id == "agent-deadbeef")')
assert_eq "nested subagent transcript is scanned" "1" "$(jq -r '.total_calls' <<< "$SUB")"
assert_eq "nested subagent keeps the parent project slug" "$OTHER_SLUG" "$(jq -r '.project' <<< "$SUB")"

echo "=== 4. dedup + refresh on re-run ==="
run_census --project "$SLUG" >/dev/null
assert_eq "re-run does not duplicate rows" "2" "$(wc -l < "$OUT" | tr -d ' ')"

cat >> "$SESSION_A" <<'JSONL'
{"type":"assistant","timestamp":"2026-08-20T10:05:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_a4","name":"Bash","input":{}}]}}
JSONL
run_census --project "$SLUG" >/dev/null
assert_eq "a grown session still holds one row" "1" \
    "$(jq -s --arg s "11111111-aaaa-bbbb-cccc-000000000001" '[.[] | select(.session_id == $s)] | length' "$OUT")"
assert_eq "the retained row is the refreshed one" "4" \
    "$(row_for "11111111-aaaa-bbbb-cccc-000000000001" | jq -r '.total_calls')"
assert_eq "unrelated rows survive the merge" "1" \
    "$(jq -s --arg s "22222222-aaaa-bbbb-cccc-000000000002" '[.[] | select(.session_id == $s)] | length' "$OUT")"

echo "=== 4b. a corrupt census row does not take the rest of the file with it ==="
# Scan a DIFFERENT project so the surviving rows are ones this pass did not
# re-emit — the merge, not the rescan, has to preserve them.
printf '{half-written\n' >> "$OUT"
run_census --project "$OTHER_SLUG" >/dev/null
assert_eq "the corrupt row is dropped" "0" "$(grep -c 'half-written' "$OUT" || true)"
assert_eq "history from an unscanned project survives" "1" \
    "$(jq -s --arg s "22222222-aaaa-bbbb-cccc-000000000002" '[.[] | select(.session_id == $s)] | length' "$OUT")"
assert_eq "the newly scanned project is merged in" "1" \
    "$(jq -s --arg s "44444444-aaaa-bbbb-cccc-000000000004" '[.[] | select(.session_id == $s)] | length' "$OUT")"

echo "=== 4c. rows past the retention window are pruned ==="
# The fixture transcripts carry fixed dates, so every other section runs with
# retention effectively disabled (set at the top of this file); only here is a
# real window applied, against rows dated relative to NOW.
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
{
    jq -c -n '{session_id:"ancient", project:"gone", started_at:"2020-01-01T00:00:00.000Z", ended_at:"2020-01-01T01:00:00.000Z", tool_calls:{Bash:{calls:1,errors:0}}, total_calls:1, total_errors:0, denials:{}}'
    jq -c -n --arg t "$NOW_ISO" '{session_id:"undated", project:"gone", started_at:$t, ended_at:null, tool_calls:{Bash:{calls:1,errors:0}}, total_calls:1, total_errors:0, denials:{}}'
    jq -c -n --arg t "$NOW_ISO" '{session_id:"recent", project:"kept", started_at:$t, ended_at:$t, tool_calls:{Bash:{calls:1,errors:0}}, total_calls:1, total_errors:0, denials:{}}'
} >> "$OUT"
HIMMEL_TOOL_CENSUS_RETAIN_DAYS=14 bash "$SCRIPT" --projects-dir "$PROJECTS" --out "$OUT" --project "$SLUG" >/dev/null
assert_eq "a row older than the retention window is dropped" "0" \
    "$(jq -s '[.[] | select(.session_id == "ancient")] | length' "$OUT")"
assert_eq "a row with no usable ended_at is dropped" "0" \
    "$(jq -s '[.[] | select(.session_id == "undated")] | length' "$OUT")"
assert_eq "an in-window row is preserved" "1" \
    "$(jq -s '[.[] | select(.session_id == "recent")] | length' "$OUT")"
rc=0; HIMMEL_TOOL_CENSUS_RETAIN_DAYS=nope bash "$SCRIPT" --projects-dir "$PROJECTS" --project "$SLUG" --stdout >/dev/null 2>&1 || rc=$?
assert_eq "a non-numeric retention window is rejected" "2" "$rc"

# A freshly-touched transcript whose last activity is years old must not enter
# the census below the retention floor and then never leave.
STALE_SESSION="$PROJECTS/$SLUG/55555555-aaaa-bbbb-cccc-000000000005.jsonl"
cat > "$STALE_SESSION" <<'JSONL'
{"type":"assistant","timestamp":"2020-03-01T09:00:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_f1","name":"Bash","input":{}}]}}
JSONL
STALE=$(HIMMEL_TOOL_CENSUS_RETAIN_DAYS=14 bash "$SCRIPT" --projects-dir "$PROJECTS" --project "$SLUG" --stdout 2>/dev/null \
    | jq -r 'select(.session_id == "55555555-aaaa-bbbb-cccc-000000000005") | .session_id')
assert_eq "a fresh transcript with stale timestamps is not emitted" "" "$STALE"

echo "=== 4d. dedup is keyed by project AND session id ==="
# Same session basename under two projects: neither row may evict the other.
jq -c -n --arg t "$NOW_ISO" '{session_id:"agent-deadbeef", project:"other-vault", started_at:$t, ended_at:$t, tool_calls:{Bash:{calls:7,errors:0}}, total_calls:7, total_errors:0, denials:{}}' >> "$OUT"
run_census --project "$OTHER_SLUG" >/dev/null
assert_eq "the same basename under another project survives" "7" \
    "$(jq -s '[.[] | select(.session_id == "agent-deadbeef" and .project == "other-vault")] | .[0].total_calls' "$OUT")"
assert_eq "the rescanned project's own row is refreshed, not duplicated" "1" \
    "$(jq -s --arg p "$OTHER_SLUG" '[.[] | select(.session_id == "agent-deadbeef" and .project == $p)] | length' "$OUT")"

echo "=== 5. --since windows by transcript mtime ==="
touch -d "@1000000000" "$SESSION_B" 2>/dev/null || touch -t 200109090146 "$SESSION_B"
FRESH=$(bash "$SCRIPT" --projects-dir "$PROJECTS" --project "$SLUG" --since 1h --stdout 2>/dev/null | jq -r '.session_id' | tr '\n' ' ')
case "$FRESH" in
    *"11111111-aaaa-bbbb-cccc-000000000001"*) pass "recent transcript inside the window" ;;
    *) fail "recent transcript inside the window" "got: $FRESH" ;;
esac
case "$FRESH" in
    *"22222222-aaaa-bbbb-cccc-000000000002"*) fail "stale transcript excluded" "got: $FRESH" ;;
    *) pass "stale transcript excluded" ;;
esac

echo "=== 6. argument validation ==="
rc=0; bash "$SCRIPT" --projects-dir "$PROJECTS" --since 4x --stdout >/dev/null 2>&1 || rc=$?
assert_eq "bad --since rejected" "2" "$rc"
rc=0; bash "$SCRIPT" --projects-dir "$PROJECTS" --project no-such-slug --stdout >/dev/null 2>&1 || rc=$?
assert_eq "unknown --project rejected" "2" "$rc"
rc=0; bash "$SCRIPT" --projects-dir "$TMP_ROOT/absent" --stdout >/dev/null 2>&1 || rc=$?
assert_eq "missing transcript root rejected" "2" "$rc"
rc=0; bash "$SCRIPT" --nonsense >/dev/null 2>&1 || rc=$?
assert_eq "unknown flag rejected" "2" "$rc"
rc=0; bash "$SCRIPT" --projects-dir "$PROJECTS" --since >/dev/null 2>&1 || rc=$?
assert_eq "value-less option rejected with the documented status" "2" "$rc"
# `08`/`09` are invalid octal to $(( )), which used to abort the whole run.
rc=0; bash "$SCRIPT" --projects-dir "$PROJECTS" --project "$SLUG" --since 08h --stdout >/dev/null 2>&1 || rc=$?
assert_eq "leading-zero duration accepted" "0" "$rc"

echo "=== 7. the merge is single-writer ==="
mkdir "$OUT.lock"
rc=0; bash "$SCRIPT" --projects-dir "$PROJECTS" --project "$SLUG" --out "$OUT" >/dev/null 2>&1 || rc=$?
assert_eq "a held lock refuses the merge instead of racing it" "2" "$rc"
assert_eq "the refusing run leaves the lock for its owner" "0" "$([ -d "$OUT.lock" ] && echo 0 || echo 1)"
rmdir "$OUT.lock"
rc=0; bash "$SCRIPT" --projects-dir "$PROJECTS" --project "$SLUG" --out "$OUT" >/dev/null 2>&1 || rc=$?
assert_eq "the merge runs again once the lock is released" "0" "$rc"
assert_eq "a completed run releases its own lock" "1" "$([ -d "$OUT.lock" ] && echo 0 || echo 1)"

summary
