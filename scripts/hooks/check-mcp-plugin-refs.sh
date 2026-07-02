#!/usr/bin/env bash
# Pre-commit gate (pre-commit framework, not Claude PreToolUse).
#
# Defense-in-depth for the jira-plugin-first rule. Refuses commits whose
# staged content references any of the 8 Atlassian MCP tools with a
# documented plugin equivalent in CLAUDE.md. Catches the case where the
# Claude PreToolUse hook (block-mcp-when-plugin-exists.sh) was bypassed
# or disabled and an MCP call snuck into a skill / command / script file.
#
# The Claude hook itself + its smoke test are the only legitimate places
# that should reference these names — they're exempted by basename match.
#
# Exit codes:
#   0 — clean (no references in staged files or only in exempted files)
#   1 — refs found in non-exempt staged file
set -uo pipefail

# Eight blocked tools, alternated for one grep pass. Keep in sync with
# scripts/hooks/block-mcp-when-plugin-exists.sh.
# `\b` is GNU-only in grep -E; BSD grep on macOS treats it as a literal.
# Use `($|[^A-Za-z0-9_])` instead for portable right-anchoring against
# extensions like `getJiraIssueXYZ` or `getJiraIssueRemoteIssueLinks`.
PATTERN='mcp__plugin_atlassian_atlassian__(getJiraIssue|searchJiraIssuesUsingJql|createJiraIssue|editJiraIssue|addCommentToJiraIssue|getTransitionsForJiraIssue|transitionJiraIssue|getVisibleJiraProjects)($|[^A-Za-z0-9_])'

# Self-test PATTERN at startup. A regex compile failure or accidental
# de-anchoring would otherwise let every commit through silently.
if ! printf 'mcp__plugin_atlassian_atlassian__getJiraIssue\n' | grep -E "$PATTERN" >/dev/null 2>&1; then
    echo "check-mcp-plugin-refs: PATTERN failed self-test — refusing" >&2
    exit 1
fi

# Files allowed to reference these names — the hook implementation, its
# smoke test, this gate, and its smoke test. Match repo-relative path
# (not basename) so an attacker cannot drop an evil file at any path
# with one of these basenames and inherit the exemption.
is_exempt() {
    case "$1" in
        scripts/hooks/block-mcp-when-plugin-exists.sh) return 0 ;;
        scripts/hooks/test-block-mcp-when-plugin-exists.sh) return 0 ;;
        scripts/hooks/block-backend-tier.sh) return 0 ;;
        scripts/hooks/test-block-backend-tier.sh) return 0 ;;
        scripts/hooks/check-mcp-plugin-refs.sh) return 0 ;;
        scripts/hooks/test-check-mcp-plugin-refs.sh) return 0 ;;
        *) return 1 ;;
    esac
}

# pre-commit framework passes staged filenames as argv (we declare
# pass_filenames: true). Fall back to a diff if argv is empty so
# always_run usage also works.
files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
    # bash 3.2-safe (macOS): no mapfile.
    while IFS= read -r _line; do files+=("$_line"); done < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
fi
[ "${#files[@]}" -eq 0 ] && exit 0

violations=()
for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    is_exempt "$f" && continue
    if grep -E -l "$PATTERN" -- "$f" >/dev/null 2>&1; then
        violations+=("$f")
    fi
done

if [ "${#violations[@]}" -eq 0 ]; then
    exit 0
fi

{
    echo "⛔ check-mcp-plugin-refs: staged file(s) reference Atlassian MCP tools that have a plugin equivalent."
    echo
    for f in "${violations[@]}"; do
        echo "  $f"
        grep -E -n "$PATTERN" -- "$f" 2>/dev/null | sed 's/^/    /'
    done
    echo
    echo "Use the himmel-jira plugin instead — see CLAUDE.md 'Jira tooling — prefer plugin over MCP'."
    echo "If this file legitimately needs the raw MCP name (e.g., a hook implementation),"
    echo "add its basename to the is_exempt allowlist in scripts/hooks/check-mcp-plugin-refs.sh."
} >&2
exit 1
