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
# gh carve-out (HIMMEL-675): issue ops + pr/run READS allow; everything else denies.
assert_rc "glm gh pr create"             2 "$(run_case "$(j_bash 'gh pr create --fill')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh pr merge"              2 "$(run_case "$(j_bash 'gh pr merge 856 --squash')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh pr comment"           2 "$(run_case "$(j_bash 'gh pr comment 856 --body x')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh api"                   2 "$(run_case "$(j_bash 'gh api repos/o/r/issues -f title=x')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh repo delete"           2 "$(run_case "$(j_bash 'gh repo delete o/r')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm bare gh"                  2 "$(run_case "$(j_bash 'gh')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh compound smuggle"      2 "$(run_case "$(j_bash 'gh pr view 1 && gh pr merge 1')" "ANTHROPIC_BASE_URL=$GLM_URL")"
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
# gh issue ops + pr/run reads are operator-allowed on-lane (HIMMEL-675 carve-out).
assert_rc "glm gh issue list (allowed)"    0 "$(run_case "$(j_bash 'gh issue list')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh issue create (allowed)"  0 "$(run_case "$(j_bash 'gh issue create --title x --body y')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh issue comment (allowed)" 0 "$(run_case "$(j_bash 'gh issue comment 858 --body done')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh issue close (allowed)"   0 "$(run_case "$(j_bash 'gh issue close 858')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh pr view (allowed)"       0 "$(run_case "$(j_bash 'gh pr view 856')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh pr diff (allowed)"       0 "$(run_case "$(j_bash 'gh pr diff 856')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh pr checks (allowed)"     0 "$(run_case "$(j_bash 'gh pr checks 856')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh pr list (allowed)"       0 "$(run_case "$(j_bash 'gh pr list')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh run list (allowed)"      0 "$(run_case "$(j_bash 'gh run list')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh run watch (allowed)"     0 "$(run_case "$(j_bash 'gh run watch 123')" "ANTHROPIC_BASE_URL=$GLM_URL")"
# qmd KB reads are operator-allowed on-lane (carve-out before the blanket mcp
# deny), but COLLECTION-SCOPED to "himmel" only (HIMMEL-1239) — an unscoped
# query (no collections filter) could hit salus (PHI vault) and must deny.
assert_rc "glm mcp qmd query unscoped (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd query scoped himmel (allowed)" 0 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":["himmel"]}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd query scoped salus (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":["salus"]}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd query scoped luna (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":["luna"]}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd query mixed himmel+salus (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":["himmel","salus"]}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd query empty collections array (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":[]}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
# CR round 1 (codex-2): collections must be a JSON ARRAY — an object's VALUES
# must not satisfy the allow-list via `.[]` (e.g. {"x":"himmel"} must deny,
# matching the Python-side isinstance(collections, list) contract).
assert_rc "glm mcp qmd query collections object not array (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":{"x":"himmel"}}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
# CodeRabbit PR #1353: himmel + a BLANK entry must still deny — the earlier
# extract+grep-vxF shell round-trip let this through because the empty jq -r
# line collapsed out via command-substitution trailing-newline stripping.
assert_rc "glm mcp qmd query himmel+blank entry (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":["himmel",""]}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
# get/multi_get: only a fully-qualified qmd://himmel/... path is positively
# scoped; bare paths and #docids are cross-collection-ambiguous (deny).
assert_rc "glm mcp qmd get scoped himmel (allowed)" 0 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__get","tool_input":{"file":"qmd://himmel/README.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd get scoped salus (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__get","tool_input":{"file":"qmd://salus/patient.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd get bare filename unscoped (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__get","tool_input":{"file":"README.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd get docid unscoped (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__get","tool_input":{"file":"#abc123"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
# CR round 5 (codex-1 r5): qmd_himmel_scoped was grep-based (per-LINE match),
# so a value with an embedded newline where any line starts with
# qmd://himmel/ passed even though the value itself starts with salus. It
# must be a whole-STRING prefix check (matches Python re.match, no MULTILINE).
QMD_NEWLINE_FILE="$(jq -n --arg file "$(printf 'qmd://salus/secret\nqmd://himmel/x')" '{tool_name:"mcp__plugin_qmd_qmd__get",tool_input:{file:$file}}')"
assert_rc "glm mcp qmd get salus-then-himmel via newline (denied)" 2 "$(run_case "$QMD_NEWLINE_FILE" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd multi_get scoped himmel (allowed)" 0 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":"qmd://himmel/*.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd multi_get mixed scoped+unscoped (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":"qmd://himmel/a.md,notes.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd multi_get luna referenced (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":"qmd://luna/*.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
# CR round 1 (glm-3): under nullglob, a glob-bearing non-himmel segment that
# matches no file must still DENY. The awk-based validation (CR round 4)
# never does pathname expansion at all, so this stays denied unconditionally
# regardless of nullglob — kept as a regression pin.
assert_rc "glm mcp qmd multi_get salus glob under nullglob (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":"qmd://salus/*.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL" "BASHOPTS=nullglob")"
# CR round 2 (codex-1 r2): a pattern of only empty comma-separated segments
# (",") must deny. Originally guarded by an explicit zero-iteration counter;
# now covered directly by the awk validation's NF==0 / empty-field checks
# (CR round 4) — kept as a regression pin.
assert_rc "glm mcp qmd multi_get comma-only pattern (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":","}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
# CR round 4 (codex-1 r4) — ROOT CAUSE: bash word-splitting DROPS empty
# comma-separated fields, so a trailing/leading/adjacent-comma pattern lost
# its empty segment and was wrongly allowed despite containing one. The awk
# -F',' replacement preserves empty fields (NF counts them), matching
# Python's `pattern.split(",")` exactly — these three must all deny.
assert_rc "glm mcp qmd multi_get trailing comma (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":"qmd://himmel/a.md,"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd multi_get leading comma (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":",qmd://himmel/a.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd multi_get adjacent commas (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":"qmd://himmel/a.md,,qmd://himmel/b.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
# status has no scoping input at all -> denied fail-closed.
assert_rc "glm mcp qmd status (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__status","tool_input":{}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
# off-lane: qmd fence does not apply — the pre-existing off-lane mcp allow
# case above ("off-lane mcp tool") already covers an unscoped qmd call
# reaching this hook when ANTHROPIC_BASE_URL is not the GLM lane.
assert_rc "off-lane mcp qmd query unscoped (allowed, off-lane)" 0 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{}}')"
assert_rc "glm Read tool ignored"        0 "$(run_case '{"tool_name":"Read","tool_input":{"file_path":"x"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm empty command"            0 "$(run_case '{"tool_name":"Bash","tool_input":{}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm multi-line prose push"    0 "$(run_case "$(j_bash "$(printf 'git commit -m "notes\nabout git push etiquette"')")" "ANTHROPIC_BASE_URL=$GLM_URL")"
# Newlines are command separators (flattened to ';'): a second-line mutation
# must NOT slip through as an "argument" of the first line.
assert_rc "glm newline gh smuggle"       2 "$(run_case "$(j_bash "$(printf 'gh pr view 1\ngh pr merge 1')")" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm newline git push"         2 "$(run_case "$(j_bash "$(printf 'echo hi\ngit push')")" "ANTHROPIC_BASE_URL=$GLM_URL")"
# Pinned over-block: quoted prose whose LINE STARTS with a blocked verb.
assert_rc "glm prose line-start push (pinned overmatch)" 2 "$(run_case "$(j_bash "$(printf 'git commit -m "notes\ngit push later"')")" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm prose remote set-url"     0 "$(run_case "$(j_bash 'git commit -m "docs: note the remote set-url tripwire"')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm prose config url"         0 "$(run_case "$(j_bash 'git commit -m "docs: update config url notes"')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm env-prefix push (pinned limitation)" 0 "$(run_case "$(j_bash 'FOO=1 git push')" "ANTHROPIC_BASE_URL=$GLM_URL")"

# --- Edge cases: jq availability + malformed input ---
assert_rc "glm jq missing fails closed"  2 "$(run_case_no_jq "$(j_bash 'git status')")"
assert_rc "glm malformed JSON allows (documented)" 0 "$(run_case '{not json' "ANTHROPIC_BASE_URL=$GLM_URL")"

# --- Escape hatch (expect rc=0 on an otherwise-blocked command) ---
assert_rc "bypass GLM_EXTERNAL_WRITES_OK" 0 "$(run_case "$(j_bash 'git push')" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_EXTERNAL_WRITES_OK=1")"

# --- grant-consult cases (escalation channel, spec G1-G12 + plan G13 F9 fast-path) ---
GRANT_DIR=""
mk_grants() { GRANT_DIR=$(mktemp -d); printf '%s\n' "$@" > "$GRANT_DIR/grants.jsonl"; }
# run a cmd on-lane with GLM_SESSION_DIR pointed at the fixture grants dir
run_case_grant() {
    local input="$1"; shift
    printf '%s' "$input" | env -u ANTHROPIC_BASE_URL -u GLM_EXTERNAL_WRITES_OK \
        "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$GRANT_DIR" "$@" bash "$HOOK" >/dev/null 2>&1
    echo "$?"
}
# count consumption lines for a grant_id in the fixture. grep -c prints "0" AND
# exits 1 on zero matches, so a `|| echo 0` would double-emit "0\n0" and break
# the expect-0 asserts (G13); swallow grep's exit and default a missing file to 0.
consumptions() { local c; c=$(grep -c "\"type\":\"consumption\",\"grant_id\":\"$1\"" "$GRANT_DIR/grants.jsonl" 2>/dev/null || true); echo "${c:-0}"; }

NOW_FAR="2999-01-01T00:00:00Z"; NOW_PAST="2000-01-01T00:00:00Z"
GH_API_GET='gh[[:space:]]+api[[:space:]]+repos/o/r([[:space:]]|$)'
GP_PUSH='git([[:space:]]+-[a-z-]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+push([[:space:]]|$)'

# G1 valid gh-api-GET grant honored + 1 consumption
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g1\",\"arm\":\"gh\",\"pattern\":\"$GH_API_GET\",\"shape\":\"read\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":3}"
assert_rc "G1 gh api GET granted"        0 "$(run_case_grant "$(j_bash 'gh api repos/o/r')")"
assert_rc "G1 consumption appended"      1 "$(consumptions g1)"
# G2 expired
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g2\",\"arm\":\"gh\",\"pattern\":\"$GH_API_GET\",\"shape\":\"read\",\"expires_at\":\"$NOW_PAST\",\"max_uses\":3}"
assert_rc "G2 expired refused"           2 "$(run_case_grant "$(j_bash 'gh api repos/o/r')")"
# G3 exhausted (max_uses:1 + 1 prior consumption)
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g3\",\"arm\":\"gh\",\"pattern\":\"$GH_API_GET\",\"shape\":\"read\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":1}" '{"type":"consumption","grant_id":"g3","ts":"2026-01-01T00:00:00Z"}'
assert_rc "G3 exhausted refused"         2 "$(run_case_grant "$(j_bash 'gh api repos/o/r')")"
# G4 only-malformed line
mk_grants '{ not json'
assert_rc "G4 malformed only fails closed" 2 "$(run_case_grant "$(j_bash 'gh api repos/o/r')")"
# G5 no GLM_SESSION_DIR at all -> unchanged deny
assert_rc "G5 no session dir unchanged"  2 "$(run_case "$(j_bash 'git push origin x')" "ANTHROPIC_BASE_URL=$GLM_URL")"
# G6 compound smuggle: grant covers gh api GET only
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g6\",\"arm\":\"gh\",\"pattern\":\"$GH_API_GET\",\"shape\":\"read\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":3}"
assert_rc "G6 compound smuggle blocked"  2 "$(run_case_grant "$(j_bash 'gh api repos/o/r && gh pr merge 1')")"
# G7 valid git-push grant honored
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g7\",\"arm\":\"git-push\",\"pattern\":\"$GP_PUSH\",\"shape\":\"write\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":3}"
assert_rc "G7 git-push granted"          0 "$(run_case_grant "$(j_bash 'git push origin x')")"
assert_rc "G7 consumption appended"      1 "$(consumptions g7)"
# G8 two honored calls, max_uses:2 -> both allowed, original line intact, 2 consumptions
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g8\",\"arm\":\"gh\",\"pattern\":\"$GH_API_GET\",\"shape\":\"read\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":2}"
ORIG_G8=$(head -1 "$GRANT_DIR/grants.jsonl")
assert_rc "G8 call 1"                    0 "$(run_case_grant "$(j_bash 'gh api repos/o/r')")"
assert_rc "G8 call 2"                    0 "$(run_case_grant "$(j_bash 'gh api repos/o/r')")"
assert_rc "G8 original grant byte-unchanged" 0 "$([ "$(head -1 "$GRANT_DIR/grants.jsonl")" = "$ORIG_G8" ] && echo 0 || echo 1)"
assert_rc "G8 two consumptions"          2 "$(consumptions g8)"
# G9 off-lane: grant never read. Feed stdin via a herestring, NOT a pipe — off
# lane the hook exits at the ANTHROPIC_BASE_URL check before reading stdin, so a
# pipe writer would take SIGPIPE (rc 141 under pipefail); a herestring has no
# live writer to signal.
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g9\",\"arm\":\"gh\",\"pattern\":\"$GH_API_GET\",\"shape\":\"read\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":3}"
G9_IN="$(j_bash 'gh api repos/o/r')"
assert_rc "G9 off-lane grant ignored"    0 "$(env -u ANTHROPIC_BASE_URL "GLM_SESSION_DIR=$GRANT_DIR" bash "$HOOK" >/dev/null 2>&1 <<<"$G9_IN"; echo $?)"
# G10 overlap grant does NOT credit sibling merge (single-alternation, F1)
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g10\",\"arm\":\"gh\",\"pattern\":\"gh[[:space:]]+pr[[:space:]]+view([[:space:]]|$)\",\"shape\":\"read\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":3}"
assert_rc "G10 overlap no-credit"        2 "$(run_case_grant "$(j_bash 'gh pr view 1 && gh pr merge 1')")"
# G11 one malformed + one valid covering grant -> honored (F7)
mk_grants '{ bad line' "{\"type\":\"grant\",\"grant_id\":\"g11\",\"arm\":\"gh\",\"pattern\":\"$GH_API_GET\",\"shape\":\"read\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":3}"
assert_rc "G11 bad line skipped, valid honored" 0 "$(run_case_grant "$(j_bash 'gh api repos/o/r')")"
assert_rc "G11 consumption appended"     1 "$(consumptions g11)"
# G12 git-push grant whose pattern matches only benign git status (no push) -> REJECTED by gate (F8)
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g12\",\"arm\":\"git-push\",\"pattern\":\"git[[:space:]]+status\",\"shape\":\"write\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":3}"
assert_rc "G12 non-push-anchored rejected" 2 "$(run_case_grant "$(j_bash 'git status && git push origin x')")"
# G13 F9 fast path: builtin-allowed command + valid UNRELATED grant present -> rc=0 AND grant neither consulted nor consumed
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g13\",\"arm\":\"git-push\",\"pattern\":\"$GP_PUSH\",\"shape\":\"write\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":3}"
assert_rc "G13 builtin-allowed fast path"       0 "$(run_case_grant "$(j_bash 'gh pr view 1')")"
assert_rc "G13 fast path did not consume grant" 0 "$(consumptions g13)"

if [ "$FAILED" -ne 0 ]; then
    echo "$FAILED case(s) FAILED"
    exit 1
fi

# Total-count guard: every assert_rc increments CASES; a drift here means a case
# was silently dropped (or an early exit skipped the tail) even though nothing
# FAILED. Update EXPECTED_CASES deliberately when adding/removing a case.
EXPECTED_CASES=104
if [ "$CASES" -ne "$EXPECTED_CASES" ]; then
    echo "CASE-COUNT MISMATCH — ran $CASES, expected $EXPECTED_CASES"
    exit 1
fi
echo "all cases passed ($CASES/$EXPECTED_CASES)"
exit 0
