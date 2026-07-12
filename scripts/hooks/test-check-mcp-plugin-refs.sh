#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-mcp-plugin-refs.sh.
#
# Uses a fake repo layout under $TMP/scripts/hooks/ so the gate's
# path-anchored is_exempt() check can be exercised. Earlier rounds used
# bare basenames in /tmp which silently passed when the gate matched
# basenames; the path-anchored gate (CR finding) requires the full
# scripts/hooks/<name> path to exempt.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/check-mcp-plugin-refs.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts/hooks"

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

# Run hook from $TMP so file args are repo-relative paths.
run_hook() {
    (cd "$TMP" && bash "$HOOK" "$@" >/dev/null 2>&1)
    echo "$?"
}

FAILED=0

# T1: file referencing blocked tool → BLOCK
cat > "$TMP/skill.md" <<EOF
Use mcp__plugin_atlassian_atlassian__getJiraIssue to fetch the issue.
EOF
rc=$(run_hook "skill.md")
assert_rc "T1 blocked tool ref" 1 "$rc"

# T2: file referencing only carve-out tool (lookupJiraAccountId) → CLEAN
cat > "$TMP/clean.md" <<EOF
mcp__plugin_atlassian_atlassian__lookupJiraAccountId is the only way to map emails.
EOF
rc=$(run_hook "clean.md")
assert_rc "T2 carve-out only" 0 "$rc"

# T3: exempt path scripts/hooks/block-mcp-when-plugin-exists.sh → CLEAN
cat > "$TMP/scripts/hooks/block-mcp-when-plugin-exists.sh" <<EOF
case mcp__plugin_atlassian_atlassian__getJiraIssue
case mcp__plugin_atlassian_atlassian__transitionJiraIssue
EOF
rc=$(run_hook "scripts/hooks/block-mcp-when-plugin-exists.sh")
assert_rc "T3 exempt hook path" 0 "$rc"

# T4: exempt smoke-test path → CLEAN
cat > "$TMP/scripts/hooks/test-block-mcp-when-plugin-exists.sh" <<EOF
mcp__plugin_atlassian_atlassian__getJiraIssue
EOF
rc=$(run_hook "scripts/hooks/test-block-mcp-when-plugin-exists.sh")
assert_rc "T4 exempt smoke test path" 0 "$rc"

# T5: self-exempt path → CLEAN
cat > "$TMP/scripts/hooks/check-mcp-plugin-refs.sh" <<EOF
mcp__plugin_atlassian_atlassian__editJiraIssue
EOF
rc=$(run_hook "scripts/hooks/check-mcp-plugin-refs.sh")
assert_rc "T5 self-exempt path" 0 "$rc"

# T6: ATTACKER PATH — same basename, different dir → BLOCK.
# This is the regression the path-anchored exemption fixes: an
# attacker-controlled vendor/evil/block-mcp-when-plugin-exists.sh used
# to inherit the basename exemption.
mkdir -p "$TMP/vendor/evil"
cat > "$TMP/vendor/evil/block-mcp-when-plugin-exists.sh" <<EOF
mcp__plugin_atlassian_atlassian__getJiraIssue
EOF
rc=$(run_hook "vendor/evil/block-mcp-when-plugin-exists.sh")
assert_rc "T6 attacker basename, wrong path BLOCKS" 1 "$rc"

# T7: no files passed → CLEAN
rc=$(run_hook)
assert_rc "T7 no files" 0 "$rc"

# T8: each of the 8 blocked tool names triggers a refusal
for tool in getJiraIssue searchJiraIssuesUsingJql createJiraIssue \
            editJiraIssue addCommentToJiraIssue getTransitionsForJiraIssue \
            transitionJiraIssue getVisibleJiraProjects; do
    cat > "$TMP/v.md" <<EOF
calls mcp__plugin_atlassian_atlassian__${tool} here
EOF
    rc=$(run_hook "v.md")
    assert_rc "T8 blocks $tool" 1 "$rc"
done

# T9: stderr names the offending file
out=$(cd "$TMP" && bash "$HOOK" "v.md" 2>&1 1>/dev/null) || true
case "$out" in
    *"v.md"*) echo "PASS T9 stderr names file" ;;
    *) echo "FAIL T9 stderr did not name file"; FAILED=$((FAILED + 1)) ;;
esac

# T10: PATTERN right-anchor — getJiraIssueRemoteIssueLinks must NOT
# match getJiraIssue. This is the carve-out we depend on; a regex
# regression here silently breaks the gate.
cat > "$TMP/carveout.md" <<EOF
mcp__plugin_atlassian_atlassian__getJiraIssueRemoteIssueLinks is a carve-out.
EOF
rc=$(run_hook "carveout.md")
assert_rc "T10 RemoteIssueLinks not caught by getJiraIssue" 0 "$rc"

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
