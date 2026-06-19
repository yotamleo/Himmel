#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-backend-tier.sh (HIMMEL-400).
#
# Covers:
#   - All original Jira test cases (1:1 migration from test-block-mcp-when-plugin-exists.sh)
#   - chain-reorder via fixture registry lifts the block
#   - enabled:false lifts the block
#   - MCP_ALL_OK=1 lifts all blocks
#   - Malformed / absent BACKENDS_REGISTRY → code defaults still block Jira
#   - Non-jira MCP prefix passes through (no prefix registered)
#   - Refusal message contains the api-preference advisory when chain has api tier
#
# Usage: bash scripts/hooks/test-block-backend-tier.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/block-backend-tier.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

# --- Stub CLI factory -------------------------------------------------------
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# make_stub <path> <verb>... — emits each verb on --list-commands; any other
# argv exits 1.
make_stub() {
    local path="$1"; shift
    {
        echo '#!/usr/bin/env node'
        echo 'if (process.argv.includes("--list-commands")) {'
        for verb in "$@"; do
            echo "  console.log(\"$verb\");"
        done
        echo '  process.exit(0);'
        echo '}'
        echo 'process.exit(1);'
    } > "$path"
}

# Full verb set (mirrors the real Jira CLI today).
STUB_FULL="$TMPDIR_TEST/cli-full.js"
make_stub "$STUB_FULL" get create list transition transitions comment \
    attach edit move projects project-create link

# Reduced: 'link' and 'create' removed.
STUB_REDUCED="$TMPDIR_TEST/cli-reduced.js"
make_stub "$STUB_REDUCED" get list transition comment edit projects

# Errors on --list-commands → introspection failure → fail open.
STUB_ERR="$TMPDIR_TEST/cli-err.js"
{
    echo '#!/usr/bin/env node'
    echo 'process.exit(3);'
} > "$STUB_ERR"

# Emits nothing on --list-commands but exits 0 → empty → fail open.
STUB_EMPTY="$TMPDIR_TEST/cli-empty.js"
{
    echo '#!/usr/bin/env node'
    echo 'process.exit(0);'
} > "$STUB_EMPTY"

# Only 'transitions' (NOT 'transition') → substring guard fixture.
STUB_TRANS_ONLY="$TMPDIR_TEST/cli-transitions-only.js"
make_stub "$STUB_TRANS_ONLY" get transitions

# --- Registry fixture helpers -----------------------------------------------
# write_registry <path> <json> — write a fixture backends.json.
write_registry() {
    local path="$1" content="$2"
    printf '%s' "$content" > "$path"
}

# Registry with chain [mcp,cli,api] → mcp ranked above cli → no hard block.
REG_MCP_FIRST="$TMPDIR_TEST/reg-mcp-first.json"
write_registry "$REG_MCP_FIRST" "$(cat <<'ENDJSON'
{
  "jira": {
    "enabled": true,
    "mcp_prefix": "mcp__plugin_atlassian_atlassian__",
    "cli": "__STUB__",
    "chain": ["mcp", "cli", "api"]
  }
}
ENDJSON
)"

# Registry with jira disabled → allow.
REG_DISABLED="$TMPDIR_TEST/reg-disabled.json"
write_registry "$REG_DISABLED" "$(cat <<'ENDJSON'
{
  "jira": {
    "enabled": false,
    "mcp_prefix": "mcp__plugin_atlassian_atlassian__",
    "cli": "__STUB__",
    "chain": ["cli", "api", "mcp"]
  }
}
ENDJSON
)"

# Registry with cli:api:mcp (same as default) using STUB_FULL path.
REG_NORMAL="$TMPDIR_TEST/reg-normal.json"
write_registry "$REG_NORMAL" "{
  \"jira\": {
    \"enabled\": true,
    \"mcp_prefix\": \"mcp__plugin_atlassian_atlassian__\",
    \"cli\": \"${STUB_FULL}\",
    \"chain\": [\"cli\", \"api\", \"mcp\"]
  }
}"

# Malformed JSON.
REG_BAD="$TMPDIR_TEST/reg-bad.json"
printf 'not valid json at all' > "$REG_BAD"

# Non-existent path.
REG_MISSING="$TMPDIR_TEST/does-not-exist.json"

# --- Test harness ------------------------------------------------------------
FAILED=0

run_case() {
    local input="$1"
    local cli="${2:-$STUB_FULL}"
    local extra_env="${3:-}"
    # Build env: always set JIRA_CLI for backward compat seam.
    local cmd_env="JIRA_CLI=$cli"
    if [ -n "$extra_env" ]; then
        printf '%s' "$input" | env "$cmd_env" "$extra_env" bash "$HOOK" >/dev/null 2>&1
    else
        printf '%s' "$input" | env "$cmd_env" bash "$HOOK" >/dev/null 2>&1
    fi
    echo "$?"
}

# run_case_reg: use BACKENDS_REGISTRY instead of JIRA_CLI seam.
run_case_reg() {
    local input="$1" registry="$2" extra_env="${3:-}"
    if [ -n "$extra_env" ]; then
        printf '%s' "$input" | env "BACKENDS_REGISTRY=$registry" "$extra_env" bash "$HOOK" >/dev/null 2>&1
    else
        printf '%s' "$input" | env "BACKENDS_REGISTRY=$registry" bash "$HOOK" >/dev/null 2>&1
    fi
    echo "$?"
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_stderr_contains() {
    local label="$1" input="$2" needle="$3" cli="${4:-$STUB_FULL}"
    local out
    out=$(printf '%s' "$input" | env "JIRA_CLI=$cli" bash "$HOOK" 2>&1 >/dev/null || true)
    case "$out" in
        *"$needle"*) echo "PASS $label" ;;
        *)
            echo "FAIL $label — stderr missing: $needle"
            echo "--- got ---"
            echo "$out"
            echo "-----------"
            FAILED=$((FAILED + 1))
            ;;
    esac
}

# ============================================================================
# 1. ORIGINAL JIRA TEST CASES (1:1 migration)
# ============================================================================

echo "=== Original Jira test cases ==="

# --- Blocked tools (mapped verb present in FULL introspected set) ---
for tool in getJiraIssue searchJiraIssuesUsingJql createJiraIssue \
            editJiraIssue addCommentToJiraIssue getTransitionsForJiraIssue \
            transitionJiraIssue getVisibleJiraProjects createIssueLink; do
    rc=$(run_case "{\"tool_name\":\"mcp__plugin_atlassian_atlassian__${tool}\",\"tool_input\":{}}")
    assert_rc "block $tool (verb present)" 2 "$rc"
done

# --- Autogeneration property: REMOVE verbs from the fixture ---
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__createIssueLink","tool_input":{}}' "$STUB_REDUCED")
assert_rc "allow createIssueLink when 'link' verb absent" 0 "$rc"
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__createJiraIssue","tool_input":{}}' "$STUB_REDUCED")
assert_rc "allow createJiraIssue when 'create' verb absent" 0 "$rc"
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' "$STUB_REDUCED")
assert_rc "block getJiraIssue when 'get' verb still present" 2 "$rc"

# --- transition verb maps from TWO MCP methods ---
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__transitionJiraIssue","tool_input":{}}' "$STUB_REDUCED")
assert_rc "block transitionJiraIssue (transition present)" 2 "$rc"
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__getTransitionsForJiraIssue","tool_input":{}}' "$STUB_REDUCED")
assert_rc "block getTransitionsForJiraIssue (transition present)" 2 "$rc"

# --- Substring guard: 'transitions' must NOT trigger 'transition' match ---
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__transitionJiraIssue","tool_input":{}}' "$STUB_TRANS_ONLY")
assert_rc "allow transitionJiraIssue when only 'transitions' present (no substring match)" 0 "$rc"

# --- Stderr quality: each refusal must include the plugin verb ---
assert_stderr_contains "stderr names 'get' verb" \
    '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    'jira/dist/index.js get'
assert_stderr_contains "stderr names 'transition' verb" \
    '{"tool_name":"mcp__plugin_atlassian_atlassian__transitionJiraIssue","tool_input":{}}' \
    'jira/dist/index.js transition'
assert_stderr_contains "stderr names 'list' verb for JQL" \
    '{"tool_name":"mcp__plugin_atlassian_atlassian__searchJiraIssuesUsingJql","tool_input":{}}' \
    'jira/dist/index.js list'
assert_stderr_contains "stderr names 'link' verb" \
    '{"tool_name":"mcp__plugin_atlassian_atlassian__createIssueLink","tool_input":{}}' \
    'jira/dist/index.js link'

# --- Allowed Atlassian tools (no verb in the map → no plugin equivalent) ---
for tool in lookupJiraAccountId getJiraIssueTypeMetaWithFields \
            getJiraProjectIssueTypesMetadata getIssueLinkTypes \
            addWorklogToJiraIssue atlassianUserInfo \
            getAccessibleAtlassianResources fetch search \
            getJiraIssueRemoteIssueLinks \
            getConfluencePage createConfluencePage updateConfluencePage \
            getConfluenceSpaces searchConfluenceUsingCql; do
    rc=$(run_case "{\"tool_name\":\"mcp__plugin_atlassian_atlassian__${tool}\",\"tool_input\":{}}")
    assert_rc "allow $tool" 0 "$rc"
done

# --- Fail OPEN on introspection failure ---
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' "$STUB_ERR")
assert_rc "fail-open: introspection error allows getJiraIssue" 0 "$rc"
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' "$STUB_EMPTY")
assert_rc "fail-open: empty introspection allows getJiraIssue" 0 "$rc"
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' "$TMPDIR_TEST/does-not-exist.js")
assert_rc "fail-open: missing CLI file allows getJiraIssue" 0 "$rc"

# --- Non-Atlassian MCP tools — pass through ---
for tool in mcp__obsidian-vault__obsidian_get_file_contents \
            mcp__plugin_qmd_qmd__query \
            mcp__plugin_context7_context7__query-docs \
            mcp__plugin_playwright_playwright__browser_click; do
    rc=$(run_case "{\"tool_name\":\"${tool}\",\"tool_input\":{}}")
    assert_rc "passthrough $tool" 0 "$rc"
done

# --- Non-MCP tools (Bash, Edit, Read, etc.) — pass through ---
for tool in Bash Edit Write Read Grep PowerShell; do
    rc=$(run_case "{\"tool_name\":\"${tool}\",\"tool_input\":{}}")
    assert_rc "passthrough $tool" 0 "$rc"
done

# --- Bypass env var (backward compat MCP_JIRA_OK=1) ---
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' "$STUB_FULL" 'MCP_JIRA_OK=1')
assert_rc "bypass MCP_JIRA_OK=1" 0 "$rc"

# Bypass must produce ZERO stderr.
stderr_bytes=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    | env "JIRA_CLI=$STUB_FULL" MCP_JIRA_OK=1 bash "$HOOK" 2>&1 >/dev/null | wc -c)
assert_rc "bypass silent stderr" 0 "$stderr_bytes"

# --- Edge cases ---
rc=$(run_case '{"tool_input":{}}')
assert_rc "missing tool_name" 0 "$rc"

rc=$(run_case '')
assert_rc "empty input" 0 "$rc"

rc=$(run_case 'not json at all')
assert_rc "garbage JSON fail-closed" 2 "$rc"

rc=$(run_case "$(printf '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue\\r","tool_input":{}}')")
assert_rc "trailing CR in tool_name still blocks" 2 "$rc"

rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue ","tool_input":{}}')
assert_rc "trailing space in tool_name still blocks" 2 "$rc"

rc=$(run_case '{"tool_name":42,"tool_input":{}}')
assert_rc "non-string tool_name allows" 0 "$rc"

# ============================================================================
# 2. NEW CASES — registry-driven behaviour
# ============================================================================

echo ""
echo "=== Registry-driven cases ==="

# --- chain [mcp,cli,api] in registry → mcp ranked first → no hard block ---
# We need JIRA_CLI to still point at STUB_FULL for introspection but chain
# says mcp wins → allow.
# Build a registry that has the correct CLI path:
REG_MCP_FIRST_WITH_CLI="$TMPDIR_TEST/reg-mcp-first-with-cli.json"
write_registry "$REG_MCP_FIRST_WITH_CLI" "{
  \"jira\": {
    \"enabled\": true,
    \"mcp_prefix\": \"mcp__plugin_atlassian_atlassian__\",
    \"cli\": \"${STUB_FULL}\",
    \"chain\": [\"mcp\", \"cli\", \"api\"]
  }
}"
rc=$(run_case_reg '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' "$REG_MCP_FIRST_WITH_CLI")
assert_rc "chain [mcp,cli,api]: allow getJiraIssue (mcp ranked above cli)" 0 "$rc"

# --- enabled:false in registry → allow ---
REG_DISABLED_WITH_CLI="$TMPDIR_TEST/reg-disabled-with-cli.json"
write_registry "$REG_DISABLED_WITH_CLI" "{
  \"jira\": {
    \"enabled\": false,
    \"mcp_prefix\": \"mcp__plugin_atlassian_atlassian__\",
    \"cli\": \"${STUB_FULL}\",
    \"chain\": [\"cli\", \"api\", \"mcp\"]
  }
}"
rc=$(run_case_reg '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' "$REG_DISABLED_WITH_CLI")
assert_rc "enabled:false in registry: allow getJiraIssue" 0 "$rc"

# --- MCP_ALL_OK=1 bypasses all services ---
rc=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    | env "JIRA_CLI=$STUB_FULL" MCP_ALL_OK=1 bash "$HOOK" >/dev/null 2>&1; echo "$?")
assert_rc "MCP_ALL_OK=1 bypasses all" 0 "$rc"

# --- Malformed registry → code defaults still block Jira ---
rc=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    | env "BACKENDS_REGISTRY=$REG_BAD" "JIRA_CLI=$STUB_FULL" bash "$HOOK" >/dev/null 2>&1; echo "$?")
assert_rc "malformed registry falls back to code defaults: block getJiraIssue" 2 "$rc"

# --- Absent BACKENDS_REGISTRY path → code defaults still block Jira ---
rc=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    | env "BACKENDS_REGISTRY=$REG_MISSING" "JIRA_CLI=$STUB_FULL" bash "$HOOK" >/dev/null 2>&1; echo "$?")
assert_rc "absent registry path falls back to code defaults: block getJiraIssue" 2 "$rc"

# --- Service with no mcp_prefix (bitbucket/github in defaults) — passthrough ---
# Bitbucket doesn't have a registered mcp_prefix in defaults, so any
# mcp__plugin_bitbucket__* style call should pass through (no prefix match).
rc=$(run_case '{"tool_name":"mcp__plugin_bitbucket__getSomething","tool_input":{}}')
assert_rc "no-prefix service: mcp__plugin_bitbucket__ passes through" 0 "$rc"

# --- Refusal message contains api advisory when chain includes api tier ---
# Default chain is cli:api:mcp, so api advisory should appear.
assert_stderr_contains "refusal includes api advisory" \
    '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    'raw REST (curl/WebFetch)'

# --- MCP_<SERVICE_UPPER>_OK=1 per-service bypass ---
rc=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    | env "JIRA_CLI=$STUB_FULL" MCP_JIRA_OK=1 bash "$HOOK" >/dev/null 2>&1; echo "$?")
assert_rc "MCP_JIRA_OK=1 per-service bypass" 0 "$rc"

# --- Registry with [cli,mcp] (no api) → api advisory absent from message ---
REG_NO_API="$TMPDIR_TEST/reg-no-api.json"
write_registry "$REG_NO_API" "{
  \"jira\": {
    \"enabled\": true,
    \"mcp_prefix\": \"mcp__plugin_atlassian_atlassian__\",
    \"cli\": \"${STUB_FULL}\",
    \"chain\": [\"cli\", \"mcp\"]
  }
}"
out_no_api=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    | env "BACKENDS_REGISTRY=$REG_NO_API" bash "$HOOK" 2>&1 >/dev/null || true)
case "$out_no_api" in
    *"raw REST"*)
        echo "FAIL chain without api tier: api advisory unexpectedly present in stderr"
        FAILED=$((FAILED + 1))
        ;;
    *)
        echo "PASS chain without api tier: api advisory absent from stderr"
        ;;
esac

# ============================================================================
# Summary
# ============================================================================
echo ""
if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
