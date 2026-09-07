#!/usr/bin/env bash
# Tests for scripts/lib/cr-high-risk-diff.sh (HIMMEL-1718).
# Hermetic: GH_CMD is a PATH-independent stub; the suite never talks to GitHub.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/cr-high-risk-diff.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/cr-high-risk-diff.sh"

PASS=0; FAIL=0; TMP=""
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; [ $# -lt 2 ] || printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
# shellcheck disable=SC2329,SC2317
cleanup() { [ -z "$TMP" ] || rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

TMP=$(mktemp -d) || { echo "FATAL: mktemp -d failed"; exit 1; }
# The real function makes TWO gh calls: `pr view --json changedFiles` for the
# total, then `api --paginate .../files` for the (possibly multi-page) file
# list. The stub dispatches on the subcommand so tests can script each
# response independently, including a files response spanning several raw
# pages (GH_STUB_FILES_PAGES may itself be several concatenated JSON arrays,
# matching what `gh api --paginate` actually emits to stdout).
cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_STUB_ARGS"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    [ "${GH_STUB_TOTAL_RC:-0}" -eq 0 ] || exit "$GH_STUB_TOTAL_RC"
    printf '%s\n' "${GH_STUB_TOTAL_JSON:-}"
elif [ "$1" = "api" ]; then
    [ "${GH_STUB_FILES_RC:-0}" -eq 0 ] || exit "$GH_STUB_FILES_RC"
    printf '%s\n' "${GH_STUB_FILES_PAGES:-}"
else
    exit 1
fi
EOF
chmod +x "$TMP/gh" || { echo "FATAL: chmod failed"; exit 1; }
export GH_CMD="$TMP/gh"
export GH_STUB_ARGS="$TMP/args"

probe() {
    local total_json="$1" files_pages="$2" total_rc="${3:-0}" files_rc="${4:-0}"
    : > "$GH_STUB_ARGS"
    OUT=""; RC=0
    OUT=$(GH_STUB_TOTAL_JSON="$total_json" GH_STUB_FILES_PAGES="$files_pages" \
          GH_STUB_TOTAL_RC="$total_rc" GH_STUB_FILES_RC="$files_rc" \
          cr_diff_is_high_risk octo demo 42) || RC=$?
}
expect() {
    local want_rc="$1" want_out="$2" label="$3"
    if [ "$RC" -eq "$want_rc" ] && [ "$OUT" = "$want_out" ]; then
        pass "$label"
    else
        fail "$label" "rc=$RC want=$want_rc; out='$OUT' want='$want_out'"
    fi
}
total_json() { printf '{"changedFiles":%s}' "$1"; }
risk_page() { printf '[{"filename":"%s","status":"modified"}]' "$1"; }

echo "test-cr-high-risk-diff.sh"

probe "$(total_json 1)" "$(risk_page README.md)"
expect 1 "" "ordinary README diff -> rc 1"
if grep -Fxq 'pr view 42 --repo octo/demo --json changedFiles' "$GH_STUB_ARGS" \
   && grep -Fxq 'api --paginate repos/octo/demo/pulls/42/files' "$GH_STUB_ARGS"; then
    pass "total (pr view) and paginated file list are both requested"
else
    fail "total (pr view) and paginated file list are both requested" "args: $(cat "$GH_STUB_ARGS")"
fi

for path in \
    scripts/hooks/pre-tool.sh \
    .claude/settings.json \
    .claude/settings.local.json \
    .codex/hooks.json \
    scripts/guardrails/lib.sh \
    tools/nightly-cadence-runner.sh \
    scripts/luna/pipeline-cadence.sh \
    scripts/check-ci.sh \
    scripts/cr/clear-cr-marker.sh \
    scripts/cr/pr-merge.sh \
    scripts/cr/critic-panel.sh \
    scripts/cr/ledger-append.sh \
    .claude/commands/pr-check.md \
    .agents/skills/pr-check/SKILL.md \
    marketplace/plugins/himmel-ops/hooks/hooks.json \
    scripts/glm/ship-branch.sh \
    .codex/run-hook.cmd \
    .codex/run-hook.sh \
    .codex/codex-hook-adapter.sh \
    scripts/lib/cr-signal.sh \
    .pre-commit-config.yaml
do
    probe "$(total_json 1)" "$(risk_page "$path")"
    expect 0 "$path" "high-risk path classified: $path"
done

# The evidence producers specifically: the panel carry trusts the exact-head
# ledger, so whatever RUNS the reviewers or PERSISTS their findings must not be
# classifiable as an ordinary diff — otherwise a branch edits its own review
# machinery and manufactures the clean evidence that carries its stale review.
# (Covered by the loop above; called out here so a future narrowing of the
# scripts/cr/* pattern fails loudly on the reason rather than on a path list.)

# merge-on-green.sh is HIGH-RISK (HIMMEL-1744): it EXECUTES the squash-merge
# unattended under the ARMAUTOMERGE=1 standing allow, and check-ci.sh — its own
# green gate — consults this classifier's panel-carry, so a self-edit can merge
# a PR the review gate did not clear. Operator ruling 2026-08-12 reversed the
# 2026-08-11 scope-out on this single path. Pinned structurally so a later
# narrowing cannot drop it by accident.
probe "$(total_json 1)" "$(risk_page scripts/handover/merge-on-green.sh)"
expect 0 "scripts/handover/merge-on-green.sh" "post-gate merge driver is HIGH-RISK (merge-on-green.sh, HIMMEL-1744)"

probe "" "" 1 0
expect 2 "query-failed" "gh total (pr view) query failure -> rc 2"
probe "$(total_json 1)" "" 0 1
expect 2 "query-failed" "gh paginated file-list query failure -> rc 2"
probe '{not-json' "$(risk_page README.md)"
expect 2 "malformed-response" "malformed total JSON -> rc 2"
probe '{"changedFiles":"1"}' "$(risk_page README.md)"
expect 2 "malformed-response" "non-numeric changedFiles -> rc 2"
probe "$(total_json 1)" '{}'
expect 2 "malformed-response" "non-array files -> rc 2"
probe "$(total_json 101)" "$(risk_page README.md)"
expect 2 "truncated-files:1/101" "truncated files list -> rc 2"

# The historical failure mode this fix targets: `gh pr view --json files`
# capped at 100 files in one call, so a protected path past the first page
# was invisible. Simulate a real multi-page `gh api --paginate` response
# (two separate raw JSON arrays, exactly as gh emits them) with the protected
# path ONLY on the second page.
MULTI_PAGE=$(printf '%s\n%s' "$(risk_page README.md)" "$(risk_page scripts/hooks/deep.sh)")
probe "$(total_json 2)" "$MULTI_PAGE"
expect 0 "scripts/hooks/deep.sh" "protected path visible only on page 2 of a paginated response -> HIGH RISK"

probe "$(total_json 3)" "$MULTI_PAGE"
expect 2 "truncated-files:2/3" "flattened multi-page count is still checked against changedFiles"

probe "$(total_json 2)" '[{"filename":"scripts/hooks/one.sh","status":"modified"},{"filename":"scripts/lib/cr-two.sh","status":"added"}]'
expect 0 "scripts/hooks/one.sh,scripts/lib/cr-two.sh" "multiple matches are comma-joined"

# Renames fail closed: the response carries only the NEW path, so a protected
# file moved OUT of scripts/hooks/ would otherwise read as an ordinary diff
# while the hook is deleted. Cannot-determine (rc 2) => caller treats as high risk.
probe "$(total_json 1)" '[{"filename":"docs/moved.sh","status":"renamed","previous_filename":"scripts/hooks/old.sh"}]'
expect 2 "renamed-file:docs/moved.sh" "rename-out of a protected path fails closed"
probe "$(total_json 1)" '[{"filename":"scripts/hooks/in.sh","status":"renamed","previous_filename":"docs/old.sh"}]'
expect 2 "renamed-file:scripts/hooks/in.sh" "rename-in is also cannot-determine"
probe "$(total_json 1)" "$(risk_page README.md)"
expect 1 "" "a non-rename status stays ordinary"

# An absent `status` field is malformed-response, not "assume not renamed":
# defaulting a missing field would fail OPEN on a response that cannot prove
# a rename either way, so it degrades loudly to "high risk" instead.
probe "$(total_json 1)" '[{"filename":"scripts/hooks/x.sh"}]'
expect 2 "malformed-response" "absent status field fails closed, not open"

# Same posture for `previous_filename`: the REST endpoint always sets it on a
# renamed entry, so a response claiming status=renamed without it is
# malformed, not a silently-accepted rename.
probe "$(total_json 1)" '[{"filename":"docs/moved.sh","status":"renamed"}]'
expect 2 "malformed-response" "renamed entry missing previous_filename fails closed, not open"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
