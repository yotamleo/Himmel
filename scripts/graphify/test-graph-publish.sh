#!/usr/bin/env bash
# Smoke test for scripts/graphify/graph-publish.sh (HIMMEL-1129).
#
# Strategy (mirrors scripts/handover/test-pr-open.sh): git operations run for
# real against a LOCAL bare "origin" repo (never real GitHub) — this exercises
# the actual checkout/commit/push plumbing. `gh` is never invoked against real
# GitHub: GH_CMD points at a fake script that records args and returns canned
# JSON, and FORGE=github pins the forge seam without needing a github.com
# origin URL. --dry-run tests additionally assert NO git-mutating or gh calls
# happen at all.
#
# Covers:
#   1. --dry-run on a real diff announces the intended publish; makes no
#      checkout/commit/push/gh calls.
#   2. Refuses (rc=5) when the local graph already matches the shipped one —
#      dry-run and non-dry-run alike.
#   3. Refuses (rc=3) when graphify-out/graph.json is tracked but missing
#      from disk.
#   4. Refuses (rc=4) when the repo never tracked graphify-out/graph.json.
#   5. Refuses (rc=6) when the working tree has uncommitted changes outside
#      graphify-out/{graph.json,GRAPH_REPORT.md}.
#   6. Happy path: pushes a real commit to the local bare origin (content
#      verified), routes to `gh pr create`, commit body carries the
#      `Security reviewed: ad-hoc` attestation, and the operator's original
#      branch is restored afterward.
#   7. Refresh path: an already-open PR (per FAKE_GH_PR_LIST) routes to
#      `gh pr edit` instead of `gh pr create`.
#   8. Unknown flag exits 1 (usage error).
#   9. A pr-create failure after a successful push exits 9 (distinct partial-
#      success rc, NOT 0) — CR round 1 (codex-1): the branch IS on the bare
#      origin even though the command as a whole did not succeed.
#  10. Refuses (rc=10) when graphify-out/manifest.json (refresh-graph-map.sh's
#      transaction-complete marker) is missing — CR round 1 (codex-adv-4).
#  11. Refuses (rc=11) when GRAPH_REPORT.md is missing though graph.json +
#      manifest.json are present — CR round 2 (codex-1/codex-adv-2): the
#      report is required, never optional (this ALSO covers glm-3's finding
#      that the old optional-report code path was unreachable/broken --
#      the have_report=no path is gone entirely, not merely patched).
#  12. --base passthrough: publishing against a non-default base branch
#      actually diffs/branches off THAT ref, not main (CR round 2, glm-4).
#  13. A repo dirname with spaces sanitizes into a valid branch-name slug
#      instead of failing checkout with a confusing rc=8 (CR round 2, glm-5).
#  14. Interleaved publisher: a concurrent publish landing on the SAME target
#      branch between the recorded remote OID and our push is DETECTED and
#      REJECTED (rc=8), never silently overwritten — CR round 2 (codex-adv-1).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISH="$SCRIPT_DIR/graph-publish.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317  # invoked via trap; body reachable through it
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$name"
    else
        fail "$name" "needle '$needle' missing from haystack"
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        fail "$name" "needle '$needle' unexpectedly present"
    else
        pass "$name"
    fi
}

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$name"
    else
        fail "$name" "expected='$expected' actual='$actual'"
    fi
}

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi
echo "test: TMP_ROOT=$TMP_ROOT"

# Fake gh CLI (identical shape to test-pr-open.sh's fake) ---------------------
FAKE_GH="$TMP_ROOT/gh-fake.sh"
cat >"$FAKE_GH" <<'FAKEGH'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE_GH_LOG"
case "$1" in
    pr)
        case "$2" in
            list)
                printf '%s\n' "${FAKE_GH_PR_LIST:-}"
                exit 0
                ;;
            create)
                if [ "${FAKE_GH_FAIL:-}" = "create" ]; then
                    echo "fake gh: pr create failure" >&2
                    exit 1
                fi
                echo "https://github.com/test/test/pull/42"
                exit 0
                ;;
            edit)
                if [ "${FAKE_GH_FAIL:-}" = "edit" ]; then
                    echo "fake gh: pr edit failure" >&2
                    exit 1
                fi
                exit 0
                ;;
        esac
        ;;
esac
exit 0
FAKEGH
chmod +x "$FAKE_GH"
export FAKE_GH_LOG="$TMP_ROOT/gh.log"
: > "$FAKE_GH_LOG"

# seed_repo <dir> <bare-origin> [--no-report] — a repo on `main` with
# graphify-out/{graph.json,GRAPH_REPORT.md} committed and pushed to a local
# bare "origin", PLUS a local graphify-out/manifest.json (the refresh-graph-
# map.sh transaction-complete marker graph-publish.sh now requires) and a
# .gitignore matching himmel's real graphify-out/* pattern (manifest.json
# stays untracked/ignored, mirroring HIMMEL-1123 — its mtimes are
# machine-local so it is never committed). Without the matching .gitignore,
# manifest.json would show up as an untracked file in `git status
# --porcelain` and spuriously trip the "dirty outside graph paths" refusal.
# Returns the repo ready for the caller to dirty further.
seed_repo() {
    local repo="$1" bare="$2" with_report="${3:-yes}"
    git init -q --bare "$bare" >/dev/null 2>&1
    git init -q --initial-branch=main "$repo" 2>/dev/null || git init -q "$repo"
    (
        cd "$repo"
        git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
        mkdir -p graphify-out
        printf 'graphify-out/*\n!graphify-out/graph.json\n!graphify-out/GRAPH_REPORT.md\n' > .gitignore
        echo '{"nodes":[],"v":1}' > graphify-out/graph.json
        if [ "$with_report" = "yes" ]; then
            echo '# GRAPH_REPORT v1' > graphify-out/GRAPH_REPORT.md
        fi
        echo "readme" > README.md
        git -c user.email=t@test.com -c user.name=test add -A
        git -c user.email=t@test.com -c user.name=test commit -q -m "chore: seed"
        git branch -m main 2>/dev/null || true
        git remote add origin "$bare"
        git push -q origin main
        echo '{}' > graphify-out/manifest.json
    )
}

# Test 1/2: --dry-run announces a real diff, makes no mutating calls ---------

echo "TEST: --dry-run on a real diff announces intent and makes no mutating calls"
REPO="$TMP_ROOT/t1-repo"; BARE="$TMP_ROOT/t1-origin.git"
seed_repo "$REPO" "$BARE"
( cd "$REPO" && echo '{"nodes":[{"id":1}],"v":2}' > graphify-out/graph.json )
: > "$FAKE_GH_LOG"
rc=0
out=$(cd "$REPO" && FORGE=github GH_CMD="$FAKE_GH" bash "$PUBLISH" --dry-run --no-fetch 2>&1) || rc=$?
assert_eq        "dry-run rc=0" "0" "$rc"
assert_contains  "dry-run announces publish intent" "would publish" "$out"
branch_after=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
assert_eq        "dry-run leaves branch unchanged" "main" "$branch_after"
assert_eq        "dry-run makes no gh calls" "" "$(cat "$FAKE_GH_LOG")"
remote_sha=$(git -C "$REPO" rev-parse --verify --quiet "origin/main:graphify-out/graph.json" || echo MISSING)
work_sha=$(git -C "$REPO" hash-object graphify-out/graph.json)
if [ "$remote_sha" != "$work_sha" ]; then pass "dry-run did not push the change"; else fail "dry-run did not push the change" "remote already matches work tree"; fi

# Test: --dry-run with nothing to publish refuses rc=5 ------------------------

echo "TEST: --dry-run refuses (rc=5) when local graph already matches shipped"
REPO="$TMP_ROOT/t2-repo"; BARE="$TMP_ROOT/t2-origin.git"
seed_repo "$REPO" "$BARE"
rc=0
out=$(cd "$REPO" && FORGE=github GH_CMD="$FAKE_GH" bash "$PUBLISH" --dry-run --no-fetch 2>&1) || rc=$?
assert_eq        "nothing-to-publish rc=5" "5" "$rc"
assert_contains  "nothing-to-publish message" "nothing to publish" "$out"

# Test: refuses (rc=3) when tracked graph.json is missing from disk ----------

echo "TEST: refuses (rc=3) when graphify-out/graph.json is missing from disk"
REPO="$TMP_ROOT/t3-repo"; BARE="$TMP_ROOT/t3-origin.git"
seed_repo "$REPO" "$BARE"
( cd "$REPO" && rm -f graphify-out/graph.json )
rc=0
out=$(cd "$REPO" && FORGE=github GH_CMD="$FAKE_GH" bash "$PUBLISH" --dry-run --no-fetch 2>&1) || rc=$?
assert_eq        "missing-graph rc=3" "3" "$rc"
assert_contains  "missing-graph message" "no local" "$out"

# Test: refuses (rc=4) when the repo never tracked graphify-out/graph.json ---

echo "TEST: refuses (rc=4) when the repo never tracked graphify-out/graph.json"
REPO="$TMP_ROOT/t4-repo"; BARE="$TMP_ROOT/t4-origin.git"
git init -q --bare "$BARE" >/dev/null 2>&1
git init -q --initial-branch=main "$REPO" 2>/dev/null || git init -q "$REPO"
(
    cd "$REPO"
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    echo "readme" > README.md
    git -c user.email=t@test.com -c user.name=test add README.md
    git -c user.email=t@test.com -c user.name=test commit -q -m "chore: seed, no graph"
    git branch -m main 2>/dev/null || true
    git remote add origin "$BARE"
    git push -q origin main
)
rc=0
out=$(cd "$REPO" && FORGE=github GH_CMD="$FAKE_GH" bash "$PUBLISH" --dry-run --no-fetch 2>&1) || rc=$?
assert_eq        "untracked-graph rc=4" "4" "$rc"
assert_contains  "untracked-graph message" "does not track" "$out"

# Test: refuses (rc=10) when the refresh transaction marker is missing -------
# CR round 1 (codex-adv-4): a missing graphify-out/manifest.json means
# refresh-graph-map.sh's promote either never ran or crashed mid-way, so
# graph.json/GRAPH_REPORT.md could be an inconsistent pair.

echo "TEST: refuses (rc=10) when graphify-out/manifest.json (transaction marker) is missing"
REPO="$TMP_ROOT/t4b-repo"; BARE="$TMP_ROOT/t4b-origin.git"
seed_repo "$REPO" "$BARE"
(
    cd "$REPO"
    rm -f graphify-out/manifest.json
    echo '{"nodes":[{"id":1}],"v":2}' > graphify-out/graph.json
)
rc=0
out=$(cd "$REPO" && FORGE=github GH_CMD="$FAKE_GH" bash "$PUBLISH" --dry-run --no-fetch 2>&1) || rc=$?
assert_eq        "missing-manifest rc=10" "10" "$rc"
assert_contains  "missing-manifest message" "transaction marker is absent" "$out"

# Test: refuses (rc=6) when the working tree is dirty outside the graph paths -

echo "TEST: refuses (rc=6) on uncommitted changes outside graphify-out/*"
REPO="$TMP_ROOT/t5-repo"; BARE="$TMP_ROOT/t5-origin.git"
seed_repo "$REPO" "$BARE"
(
    cd "$REPO"
    echo '{"nodes":[{"id":1}],"v":2}' > graphify-out/graph.json
    echo "unrelated edit" >> README.md
)
rc=0
out=$(cd "$REPO" && FORGE=github GH_CMD="$FAKE_GH" bash "$PUBLISH" --dry-run --no-fetch 2>&1) || rc=$?
assert_eq        "dirty-elsewhere rc=6" "6" "$rc"
assert_contains  "dirty-elsewhere message" "outside graphify-out" "$out"
assert_contains  "dirty-elsewhere names README.md" "README.md" "$out"

# Test: happy path — real push to local bare origin, gh pr create routed -----

echo "TEST: happy path pushes a real commit and routes to gh pr create"
REPO="$TMP_ROOT/t6-repo"; BARE="$TMP_ROOT/t6-origin.git"
seed_repo "$REPO" "$BARE"
( cd "$REPO" && echo '{"nodes":[{"id":1}],"v":2}' > graphify-out/graph.json )
: > "$FAKE_GH_LOG"
rc=0
out=$(cd "$REPO" && FORGE=github GH_CMD="$FAKE_GH" FAKE_GH_PR_LIST="" bash "$PUBLISH" --no-fetch 2>&1) || rc=$?
assert_eq        "happy-path rc=0" "0" "$rc"
log=$(cat "$FAKE_GH_LOG")
assert_contains  "log has 'pr create'" "pr create" "$log"
branch_after=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
assert_eq        "operator branch restored to main" "main" "$branch_after"
pushed_content=$(git -C "$BARE" show "refs/heads/chore/graph-publish-t6-repo:graphify-out/graph.json")
assert_contains  "bare origin received the new content" '"id":1' "$pushed_content"
commit_body=$(git -C "$BARE" log -1 --format='%B' refs/heads/chore/graph-publish-t6-repo)
assert_contains  "commit carries Security reviewed trailer" "Security reviewed: ad-hoc" "$commit_body"
assert_contains  "commit subject is conventional" "chore(graphify): publish refreshed t6-repo graph" "$commit_body"

# Test: refresh path — an existing open PR routes to gh pr edit -------------

echo "TEST: refresh path routes to gh pr edit when a PR is already open"
REPO="$TMP_ROOT/t7-repo"; BARE="$TMP_ROOT/t7-origin.git"
seed_repo "$REPO" "$BARE"
( cd "$REPO" && echo '{"nodes":[{"id":1}],"v":2}' > graphify-out/graph.json )
: > "$FAKE_GH_LOG"
rc=0
out=$(cd "$REPO" && FORGE=github GH_CMD="$FAKE_GH" FAKE_GH_PR_LIST="42" bash "$PUBLISH" --no-fetch 2>&1) || rc=$?
assert_eq        "refresh-path rc=0" "0" "$rc"
log=$(cat "$FAKE_GH_LOG")
assert_contains  "log has 'pr edit 42'" "pr edit 42" "$log"
assert_not_contains "log has no 'pr create'" "pr create" "$log"

# Test: pr-create failure after a successful push is rc=9, not rc=0 ----------
# CR round 1 (codex-1): rc=0 must mean "commit + PR", never a silent partial
# success. The branch must still land on the bare origin even though the
# command overall reports failure.

echo "TEST: pr-create failure after a successful push exits 9 (branch still pushed)"
REPO="$TMP_ROOT/t9-repo"; BARE="$TMP_ROOT/t9-origin.git"
seed_repo "$REPO" "$BARE"
( cd "$REPO" && echo '{"nodes":[{"id":1}],"v":2}' > graphify-out/graph.json )
: > "$FAKE_GH_LOG"
rc=0
out=$(cd "$REPO" && FORGE=github GH_CMD="$FAKE_GH" FAKE_GH_PR_LIST="" FAKE_GH_FAIL="create" bash "$PUBLISH" --no-fetch 2>&1) || rc=$?
assert_eq        "pr-create-failure rc=9" "9" "$rc"
assert_contains  "pr-create-failure message names the branch as still pushed" "still pushed" "$out"
pushed_content=$(git -C "$BARE" show "refs/heads/chore/graph-publish-t9-repo:graphify-out/graph.json" 2>/dev/null || echo MISSING)
assert_contains  "branch landed on bare origin despite PR failure" '"id":1' "$pushed_content"

# Test: refuses (rc=11) when GRAPH_REPORT.md is missing but graph.json +
# manifest.json are present -- CR round 2 (codex-1/codex-adv-2). The report
# is now REQUIRED, never optional (this also proves the old have_report=no
# code path -- where glm-3's set-e-under-assignment bug lived -- is gone).

echo "TEST: refuses (rc=11) when GRAPH_REPORT.md is missing though graph.json+manifest.json are present"
REPO="$TMP_ROOT/t10-repo"; BARE="$TMP_ROOT/t10-origin.git"
seed_repo "$REPO" "$BARE" no
(
    cd "$REPO"
    echo '{"nodes":[{"id":1}],"v":2}' > graphify-out/graph.json
)
rc=0
out=$(cd "$REPO" && FORGE=github GH_CMD="$FAKE_GH" bash "$PUBLISH" --dry-run --no-fetch 2>&1) || rc=$?
assert_eq        "missing-report rc=11" "11" "$rc"
assert_contains  "missing-report message" "GRAPH_REPORT.md is missing" "$out"

# Test: --base passthrough actually targets the given branch -----------------
# CR round 2 (glm-4): publish against a non-default base and confirm the
# script diffed/branched off THAT ref, not the default `main`.

echo "TEST: --base passthrough diffs/branches off the given ref, not main"
REPO="$TMP_ROOT/t11-repo"; BARE="$TMP_ROOT/t11-origin.git"
seed_repo "$REPO" "$BARE"
(
    cd "$REPO"
    # develop = same commit as main (no divergence needed): the assertion
    # below checks WHICH ref the dry-run message names, which is a direct,
    # unambiguous proof of --base passthrough on its own.
    git branch develop
    git push -q origin develop
    git checkout -q develop
    # An UNCOMMITTED local change vs whatever develop/main both point at --
    # this is the "something to publish" a correct --base develop must see.
    echo '{"nodes":[{"id":"local-uncommitted"}],"v":2}' > graphify-out/graph.json
)
: > "$FAKE_GH_LOG"
rc=0
out=$(cd "$REPO" && FORGE=github GH_CMD="$FAKE_GH" bash "$PUBLISH" --dry-run --no-fetch --base develop 2>&1) || rc=$?
git -C "$REPO" checkout -q main
assert_eq        "base-passthrough rc=0 (something to publish against develop)" "0" "$rc"
assert_contains  "base-passthrough dry-run names develop" "against origin/develop" "$out"

# Test: a repo dirname with spaces sanitizes into a valid branch slug --------
# CR round 2 (glm-5): a branch-hostile corpus name must not reach `git
# checkout -B` verbatim and fail there with a confusing generic rc=8.

echo "TEST: corpus dirname with spaces sanitizes into a valid branch-name slug"
REPO="$TMP_ROOT/t12 space repo"; BARE="$TMP_ROOT/t12-origin.git"
seed_repo "$REPO" "$BARE"
( cd "$REPO" && echo '{"nodes":[{"id":1}],"v":2}' > graphify-out/graph.json )
: > "$FAKE_GH_LOG"
rc=0
out=$(cd "$REPO" && FORGE=github GH_CMD="$FAKE_GH" FAKE_GH_PR_LIST="" bash "$PUBLISH" --no-fetch 2>&1) || rc=$?
assert_eq        "spaced-corpus rc=0 (no confusing checkout failure)" "0" "$rc"
branch_after=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
assert_eq        "spaced-corpus: operator branch restored to main" "main" "$branch_after"
sanitized_branch=$(git -C "$BARE" branch --list 'chore/graph-publish-*' --format='%(refname:short)')
case "$sanitized_branch" in
    *" "*) fail "spaced-corpus branch name has no spaces" "got: $sanitized_branch" ;;
    chore/graph-publish-*) pass "spaced-corpus branch name has no spaces" ;;
    *) fail "spaced-corpus branch name has no spaces" "unexpected branch: $sanitized_branch" ;;
esac

# Test: an interleaved (concurrent) publisher is DETECTED and REJECTED, never
# silently overwritten -- CR round 2 (codex-adv-1). GRAPH_PUBLISH_TEST_RACE_HOOK
# is a TEST-ONLY seam that runs right after graph-publish.sh records the
# publish branch's remote OID and BEFORE it checks out/commits/pushes -- here
# it simulates a concurrent publisher landing on that SAME (not-yet-existing)
# branch in that exact window, by pushing a commit to it from a separate clone
# of the same bare origin.

echo "TEST: an interleaved concurrent publisher is detected and rejected (rc=8), not overwritten"
REPO="$TMP_ROOT/t13-repo"; BARE="$TMP_ROOT/t13-origin.git"
seed_repo "$REPO" "$BARE"
( cd "$REPO" && echo '{"nodes":[{"id":"ours"}],"v":2}' > graphify-out/graph.json )
RACE_CLONE="$TMP_ROOT/t13-race-clone"
RACE_BRANCH="chore/graph-publish-t13-repo"
# Wrapped in a SUBSHELL (parens): `eval` runs in-process, not a forked shell,
# so an unparenthesized `cd` here would leak into graph-publish.sh's OWN
# working directory for every command after the hook -- corrupting the very
# checkout/commit/push sequence this test means to observe. Cloned with an
# explicit `-b main`: seed_repo's `git init --bare` leaves the bare's HEAD at
# an unborn default branch (master), so a branchless clone checks out NOTHING
# ("remote HEAD refers to nonexistent ref") and the hook would die writing
# graphify-out/graph.json into an empty working tree.
RACE_HOOK="(set -e; rm -rf '$RACE_CLONE'; git clone -q -b main '$BARE' '$RACE_CLONE'; cd '$RACE_CLONE'; git -c user.email=race@test.com -c user.name=race checkout -q -b '$RACE_BRANCH'; echo '{\"nodes\":[{\"id\":\"concurrent-publisher\"}]}' > graphify-out/graph.json; git -c user.email=race@test.com -c user.name=race commit -q -am 'chore: concurrent publisher landed first'; git push -q origin '$RACE_BRANCH')"
rc=0
out=$(cd "$REPO" && FORGE=github GH_CMD="$FAKE_GH" GRAPH_PUBLISH_TEST_RACE_HOOK="$RACE_HOOK" bash "$PUBLISH" --no-fetch 2>&1) || rc=$?
assert_eq        "interleaved-publisher rc=8 (rejected, not overwritten)" "8" "$rc"
assert_contains  "interleaved-publisher message names the collision" "moved on origin" "$out"
remote_content=$(git -C "$BARE" show "refs/heads/${RACE_BRANCH}:graphify-out/graph.json")
assert_contains  "concurrent publisher's commit survives on origin" "concurrent-publisher" "$remote_content"
if printf '%s' "$remote_content" | grep -qF '"ours"'; then
    fail "our stale commit did NOT overwrite the concurrent publisher's" "found 'ours' in remote content"
else
    pass "our stale commit did NOT overwrite the concurrent publisher's"
fi

# Test: unknown flag is a usage error -----------------------------------------

echo "TEST: unknown flag exits 1"
REPO="$TMP_ROOT/t8-repo"; BARE="$TMP_ROOT/t8-origin.git"
seed_repo "$REPO" "$BARE"
rc=0
out=$(cd "$REPO" && FORGE=github GH_CMD="$FAKE_GH" bash "$PUBLISH" --bogus-flag 2>&1) || rc=$?
assert_eq        "usage-error rc=1" "1" "$rc"

# Summary ----------------------------------------------------------------------

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
