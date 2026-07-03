#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-glm-external-writes.sh (HIMMEL-654 GLM
# lane hardening — deterministic classifier substitute).
#
# Usage: bash scripts/hooks/test-block-glm-external-writes.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/block-glm-external-writes.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

FAILED=0
CASES=0
GLM_URL="https://api.z.ai/api/anthropic"
BASH_ABS=$(command -v bash)
EMPTY_PATH=$(mktemp -d)

# run_case <json> [VAR=val ...] — extra args become env assignments.
run_case() {
    local input="$1"; shift
    printf '%s' "$input" | env -u ANTHROPIC_BASE_URL -u GLM_EXTERNAL_WRITES_OK "$@" bash "$HOOK" >/dev/null 2>&1
    echo "$?"
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    CASES=$((CASES + 1))
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

j_bash() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
j_pwsh() { printf '{"tool_name":"PowerShell","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

# jq-missing runner: empty PATH hides jq from the hook, but bash is invoked by
# absolute path so the script still runs and must fail closed at the jq check.
run_case_no_jq() {
    printf '%s' "$1" | env -u ANTHROPIC_BASE_URL "ANTHROPIC_BASE_URL=$GLM_URL" PATH="$EMPTY_PATH" "$BASH_ABS" "$HOOK" >/dev/null 2>&1
    echo "$?"
}

# --- OFF-LANE: everything allowed (expect rc=0) ---
assert_rc "off-lane git push"            0 "$(run_case "$(j_bash 'git push origin main')")"
assert_rc "off-lane gh pr create"        0 "$(run_case "$(j_bash 'gh pr create --title x')")"
assert_rc "off-lane mcp tool"            0 "$(run_case '{"tool_name":"mcp__plugin_github_github__merge_pull_request","tool_input":{}}')"
assert_rc "anthropic-url non-glm"        0 "$(run_case "$(j_bash 'git push')" "ANTHROPIC_BASE_URL=https://api.anthropic.com")"

# --- ON-LANE BLOCK cases (expect rc=2) ---
assert_rc "glm git push"                 2 "$(run_case "$(j_bash 'git push origin feat/x')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm git push after &&"        2 "$(run_case "$(j_bash 'bun test && git push')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm git -C path push"         2 "$(run_case "$(j_bash 'git -C /tmp/wt push')" "ANTHROPIC_BASE_URL=$GLM_URL")"
# shellcheck disable=SC2016  # literal $(git push) is the command text under test, not for expansion
assert_rc "glm git push in subshell"     2 "$(run_case "$(j_bash 'echo $(git push 2>&1)')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh pr create"             2 "$(run_case "$(j_bash 'gh pr create --fill')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh pr view (reads too)"   2 "$(run_case "$(j_bash 'gh pr view 855')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm IWR uppercase alias"      2 "$(run_case "$(j_pwsh 'IWR https://example.com')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm push after pipe"          2 "$(run_case "$(j_bash 'git status | git push')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm remote set-url"           2 "$(run_case "$(j_bash 'git remote set-url --push origin git@github.com:u/r.git')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm config pushurl"           2 "$(run_case "$(j_bash 'git config remote.origin.pushurl git@github.com:u/r.git')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm config --local pushurl"   2 "$(run_case "$(j_bash 'git config --local remote.origin.pushurl git@github.com:u/r.git')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm config --get url (pinned overmatch)" 2 "$(run_case "$(j_bash 'git config --get remote.origin.url')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh at end of command"     2 "$(run_case "$(j_bash 'cd /tmp && gh')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm iwr (PS alias)"           2 "$(run_case "$(j_pwsh 'iwr https://example.com')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm curl"                     2 "$(run_case "$(j_bash 'curl -X POST https://api.example.com -d x=1')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm wget"                     2 "$(run_case "$(j_bash 'wget https://example.com/f.tar.gz')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm Invoke-RestMethod"        2 "$(run_case "$(j_pwsh 'Invoke-RestMethod -Uri https://api.example.com -Method Post')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp github write"         2 "$(run_case '{"tool_name":"mcp__plugin_github_github__merge_pull_request","tool_input":{}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp atlassian (CLI-first, still blocked)" 2 "$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__createJiraIssue","tool_input":{}}' "ANTHROPIC_BASE_URL=$GLM_URL")"

# --- ON-LANE ALLOW cases (expect rc=0) ---
assert_rc "glm git commit"               0 "$(run_case "$(j_bash 'git commit -m "docs: fix typos"')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm commit msg says git push" 0 "$(run_case "$(j_bash 'git commit -m "explain when to git push"')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm git add/status/diff"      0 "$(run_case "$(j_bash 'git add -u && git status && git diff --stat')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm bun test"                 0 "$(run_case "$(j_bash 'bun test scripts/telegram')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm bun install"              0 "$(run_case "$(j_bash 'bun install')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm prose mentions gh"        0 "$(run_case "$(j_bash 'git commit -m "docs: gh usage notes"')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm jirafish not jira"        0 "$(run_case "$(j_bash 'echo jirafish')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm jira prose in commit msg" 0 "$(run_case "$(j_bash 'git commit -m "docs: fix scripts/jira/index"')" "ANTHROPIC_BASE_URL=$GLM_URL")"
# Jira CLI is operator-allowed on-lane (audited + recoverable, policy 2026-07-03).
assert_rc "glm jira CLI path (allowed)"  0 "$(run_case "$(j_bash 'node scripts/jira/dist/index.js transition HIMMEL-1 Done')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm bare jira (allowed)"      0 "$(run_case "$(j_bash 'jira list')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm jira direct path (allowed)" 0 "$(run_case "$(j_bash './scripts/jira/dist/index.js list')" "ANTHROPIC_BASE_URL=$GLM_URL")"
# qmd KB reads are operator-allowed on-lane (carve-out before the blanket mcp deny).
assert_rc "glm mcp qmd read (allowed)"   0 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm Read tool ignored"        0 "$(run_case '{"tool_name":"Read","tool_input":{"file_path":"x"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm empty command"            0 "$(run_case '{"tool_name":"Bash","tool_input":{}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm multi-line prose push"    0 "$(run_case "$(j_bash "$(printf 'git commit -m "notes\nabout git push etiquette"')")" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm prose remote set-url"     0 "$(run_case "$(j_bash 'git commit -m "docs: note the remote set-url tripwire"')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm prose config url"         0 "$(run_case "$(j_bash 'git commit -m "docs: update config url notes"')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm env-prefix push (pinned limitation)" 0 "$(run_case "$(j_bash 'FOO=1 git push')" "ANTHROPIC_BASE_URL=$GLM_URL")"

# --- Edge cases: jq availability + malformed input ---
assert_rc "glm jq missing fails closed"  2 "$(run_case_no_jq "$(j_bash 'git status')")"
assert_rc "glm malformed JSON allows (documented)" 0 "$(run_case '{not json' "ANTHROPIC_BASE_URL=$GLM_URL")"

# --- Escape hatch (expect rc=0 on an otherwise-blocked command) ---
assert_rc "bypass GLM_EXTERNAL_WRITES_OK" 0 "$(run_case "$(j_bash 'git push')" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_EXTERNAL_WRITES_OK=1")"

if [ "$FAILED" -ne 0 ]; then
    echo "$FAILED case(s) FAILED"
    exit 1
fi

# Total-count guard: every assert_rc increments CASES; a drift here means a case
# was silently dropped (or an early exit skipped the tail) even though nothing
# FAILED. Update EXPECTED_CASES deliberately when adding/removing a case.
EXPECTED_CASES=44
if [ "$CASES" -ne "$EXPECTED_CASES" ]; then
    echo "CASE-COUNT MISMATCH — ran $CASES, expected $EXPECTED_CASES"
    exit 1
fi
echo "all cases passed ($CASES/$EXPECTED_CASES)"
exit 0
