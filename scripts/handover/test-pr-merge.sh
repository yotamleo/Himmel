#!/usr/bin/env bash
# Tests for handover/pr-merge.sh — squash-merge guard for handover branches.
#
# HIMMEL-224: pr-merge defaults to a plain `--squash` (no `--admin`) and only
# escalates to `--admin` when the plain merge fails for a non-cosmetic reason
# AND admin-merge is authorized via GH_ADMIN_MERGE_OK=1.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_MERGE="$SCRIPT_DIR/pr-merge.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# Run pr-merge.sh in an isolated temp git repo with a stub gh on PATH.
# Args: <branch> <expected-exit> <test-name> [-- extra pr-merge args...]
# Stub behavior is controlled by env vars exported before the call:
#   STUB_PLAIN_FAIL=1  : `gh pr merge` WITHOUT --admin exits 1 with a
#                        branch-protection error.
#   STUB_ADMIN_FAIL=1  : `gh pr merge` WITH --admin exits 1.
#   STUB_COSMETIC=1    : `gh pr merge` exits 1 with the cosmetic
#                        "branch is already used by worktree" error.
#   SETUP_MERGE_CONFLICT=1 : build a real add/add conflict between the branch
#                        and main so the HIMMEL-1232 local merge-tree check
#                        returns CONFLICTING.
#   STUB_MERGE_UNKNOWN=1 : the base+head read reports a head SHA not present
#                        locally, so the check cannot verify it -> UNKNOWN
#                        (fail-open tooling-gap path).
#   STUB_MERGE_VIEW_FAIL=1 : `gh pr view --json baseRefName,headRefOid` exits 1
#                        — a transient gh/network failure (fail-open path).
# After the run, $LAST_GH_LOG holds the path to the recorded gh argv log so
# callers can assert on --admin presence/absence.
LAST_GH_LOG=""
LAST_OUT=""
LAST_ERR=""
run_case() {
    local branch="$1" expected="$2" name="$3"; shift 3
    # Drop a leading `--` separator if present.
    [ "${1:-}" = "--" ] && shift
    local tmp; tmp=$(mktemp -d)
    local ghlog="$tmp/gh.log"
    : > "$ghlog"

    mkdir -p "$tmp/bin"
    cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
verb="$1 $2"
COSMETIC_MSG="failed to run git: fatal: 'main' is already used by worktree at '/x'"
case "$verb" in
    "pr list")
        if [ "${STUB_LIST_FAIL:-0}" = "1" ]; then
            echo "gh: could not connect to api.github.com" >&2
            exit 1
        fi
        echo "42"
        ;;
    "pr view")
        # Three distinct `gh pr view` shapes reach this stub — matched by the
        # requested --json fields (order matters; the first two also contain
        # headRefOid, so the mergeability check must be matched FIRST):
        #   1. HIMMEL-1232 mergeability check: --json baseRefName,headRefOid --jq
        #   2. HIMMEL-1058 head-SHA bind read: --json headRefOid --jq .headRefOid
        #   3. HIMMEL-936 CR-gate metadata:    --json number,headRefOid,url (no --jq)
        if printf ' %s ' "$@" | grep -q 'baseRefName'; then
            # forge_pr_mergeable (github) reads base+head, then computes the
            # conflict LOCALLY with git merge-tree. Emit "<base> <headoid>":
            #   STUB_MERGE_VIEW_FAIL=1 -> gh error (backend fails open -> proceed)
            #   STUB_MERGE_UNKNOWN=1   -> a head SHA not present locally (backend
            #                             cannot verify it -> UNKNOWN -> proceed)
            #   default                -> the real current-branch tip, so
            #                             merge-tree runs against real commits
            #                             (clean by default; SETUP_MERGE_CONFLICT
            #                             built a conflicting head).
            [ "${STUB_MERGE_VIEW_FAIL:-0}" = "1" ] && { echo "gh: could not resolve PR" >&2; exit 1; }
            [ "${STUB_MERGE_UNKNOWN:-0}" = "1" ] && { echo "main deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"; exit 0; }
            echo "main $(git rev-parse HEAD)"
            exit 0
        fi
        if printf ' %s ' "$@" | grep -q 'headRefOid'; then
            # STUB_CR_BLOCK=1 arms the CR gate; STUB_CI_BLOCK=1 arms the CI gate
            # (both need parseable metadata to resolve the head SHA).
            # HIMMEL-1058: pr-merge reads the head SHA to bind the merge to it,
            # via `pr view <n> --json headRefOid --jq .headRefOid` — which on
            # real gh prints the BARE SHA, not the JSON object. The gate's
            # metadata call (--json number,headRefOid,url, no --jq) still gets
            # the object. Distinguish on --jq.
            if printf ' %s ' "$@" | grep -q -- '--jq'; then
                # STUB_HEAD_UNREADABLE=1 fails ONLY this read, exercising the
                # refuse-rather-than-merge-unbound path.
                [ "${STUB_HEAD_UNREADABLE:-0}" = "1" ] && { echo ""; exit 0; }
                echo "abc123"
            elif [ "${STUB_CR_BLOCK:-0}" = "1" ] || [ "${STUB_CI_BLOCK:-0}" = "1" ] || [ "${STUB_ALL_GREEN:-0}" = "1" ]; then
                echo '{"number":42,"headRefOid":"abc123","url":"https://github.com/o/r/pull/42"}'
            else
                # Non-JSON so cr_merge_gate degrades + fails open (existing cases
                # without STUB_CR_BLOCK/CI_BLOCK/ALL_GREEN stay green).
                echo "degraded-non-json"
            fi
            exit 0
        fi
        ;;
    "pr merge")
        is_admin=0
        for a in "$@"; do [ "$a" = "--admin" ] && is_admin=1; done
        if [ "$is_admin" -eq 0 ]; then
            # plain attempt
            [ "${STUB_COSMETIC:-0}" = "1" ]   && { echo "$COSMETIC_MSG" >&2; exit 1; }
            [ "${STUB_PLAIN_FAIL:-0}" = "1" ] && { echo "GraphQL: Protected branch update failed (mergePullRequest)" >&2; exit 1; }
        else
            # admin fallback attempt
            [ "${STUB_ADMIN_COSMETIC:-0}" = "1" ] && { echo "$COSMETIC_MSG" >&2; exit 1; }
            [ "${STUB_ADMIN_FAIL:-0}" = "1" ]     && { echo "admin merge failed" >&2; exit 1; }
        fi
        echo "merged"
        ;;
    "api graphql")
        # CR-gate reviewThreads query. STUB_CI_BLOCK=1 needs the CR gate to PASS
        # (resolved coderabbit threads) so the CI gate is reached; otherwise one
        # unresolved coderabbitai thread arms the CR block (fixture from
        # test-cr-merge-gate.sh).
        if [ "${STUB_CI_BLOCK:-0}" = "1" ] || [ "${STUB_ALL_GREEN:-0}" = "1" ]; then
            echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}'
        else
            echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}'
        fi
        ;;
    "api repos"*)
        # check-runs vs statuses, distinguished by the URL tail. Match
        # 'statuses' FIRST — '/status' is a prefix of '/statuses' and would
        # otherwise swallow it.
        # STUB_CI_BLOCK=1 returns a FAILED non-CodeRabbit check-run so the CI
        # gate blocks while the CR gate still passes.
        if printf ' %s ' "$@" | grep -q 'check-runs'; then
            if [ "${STUB_CI_BLOCK:-0}" = "1" ]; then
                echo '{"check_runs":[{"name":"tests","status":"completed","conclusion":"failure"}]}'
            else
                echo '{"check_runs":[]}'
            fi
        elif printf ' %s ' "$@" | grep -q 'statuses'; then
            # CodeRabbit's real shape: a commit STATUS with creator identity
            # (HIMMEL-1072). The CR gate requires it PRESENT + success on the
            # head; the CI gate excludes it and reads the rest.
            # Under STUB_CI_BLOCK the non-CodeRabbit `ci` status goes red too, so
            # the fixture describes ONE coherent world rather than a red check-run
            # beside a green status (coderabbit-9). It does not change any verdict
            # — ci-green-gate blocks on the red check-run in step 1 and returns
            # before it ever queries statuses — but a self-contradicting fixture
            # is a trap for the next reader.
            ci_state="success"
            [ "${STUB_CI_BLOCK:-0}" = "1" ] && ci_state="failure"
            printf '[{"context":"CodeRabbit","state":"success","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}},{"context":"ci","state":"%s","created_at":"2026-07-16T19:10:05Z","creator":{"id":1,"login":"ci","type":"Bot"}}]\n' "$ci_state"
        else
            echo '{}'
        fi
        ;;
    *) ;;
esac
STUB
    chmod +x "$tmp/bin/gh"

    (
        cd "$tmp" || exit 99
        git init -q
        git config user.email t@t.t
        git config user.name t
        git commit -q --allow-empty -m init
        # HIMMEL-1232: the github mergeability check resolves the base as
        # origin/main (absent — no fetch) then local `main`, so a `main` ref
        # must exist at the base for git merge-tree to run.
        git branch -M main
        git checkout -q -b "$branch" 2>/dev/null || git checkout -q "$branch"
        # SETUP_MERGE_CONFLICT=1: build a real add/add conflict between this
        # branch and main so forge_pr_mergeable returns CONFLICTING.
        if [ "${SETUP_MERGE_CONFLICT:-0}" = "1" ]; then
            printf 'theirs\n' > cf; git add cf; git commit -q -m theirs
            git checkout -q main
            printf 'ours\n' > cf; git add cf; git commit -q -m ours
            git checkout -q "$branch"
        fi
        # Forge seam (HIMMEL-326): pr-merge resolves the forge from origin. A
        # github origin selects the github backend, which reproduces the exact
        # `gh pr merge` shapes (incl. --admin fallback) these asserts expect.
        git remote add origin https://github.com/test/test.git
        GH_LOG="$ghlog" \
            PATH="$tmp/bin:$PATH" GH_CMD=gh \
            bash "$PR_MERGE" "$@" >"$tmp/out" 2>"$tmp/err"
    )
    local rc=$?
    LAST_GH_LOG="$ghlog"
    LAST_OUT="$tmp/out"
    # Persist log + out into a stable location so post-call asserts can read
    # them after the temp dir is cleaned.
    local keep; keep=$(mktemp -d)
    cp "$ghlog" "$keep/gh.log" 2>/dev/null
    cp "$tmp/out" "$keep/out" 2>/dev/null
    cp "$tmp/err" "$keep/err" 2>/dev/null
    LAST_GH_LOG="$keep/gh.log"
    LAST_OUT="$keep/out"
    LAST_ERR="$keep/err"
    if [ "$rc" -ne "$expected" ]; then
        fail "$name: expected exit $expected, got $rc (err: $(cat "$keep/err"))"
        rm -rf "$tmp"
        return 1
    fi
    pass
    rm -rf "$tmp"
    return 0
}

# Assert the recorded gh log contains (or not) a substring.
assert_log_has() {
    if grep -qF -- "$1" "$LAST_GH_LOG"; then pass; else fail "$2 (log: $(cat "$LAST_GH_LOG"))"; fi
}
assert_log_lacks() {
    if grep -qF -- "$1" "$LAST_GH_LOG"; then fail "$2 (log: $(cat "$LAST_GH_LOG"))"; else pass; fi
}
# Assert the captured stdout contains (or not) a substring.
assert_out_has() {
    if grep -qF -- "$1" "$LAST_OUT"; then pass; else fail "$2 (out: $(cat "$LAST_OUT"))"; fi
}
assert_out_lacks() {
    if grep -qF -- "$1" "$LAST_OUT"; then fail "$2 (out: $(cat "$LAST_OUT"))"; else pass; fi
}
assert_err_has() {
    if grep -qF -- "$1" "$LAST_ERR"; then pass; else fail "$2 (err: $(cat "$LAST_ERR"))"; fi
}

echo "test-pr-merge.sh"

# --- refusal paths (pre-existing behavior) ---
run_case "feat/foo" 3 "refuses on feat/ branch"
run_case "main" 3 "refuses on main"

# --- default merge is plain --squash, NO --admin (HIMMEL-224) ---
if run_case "handover/x-slug" 0 "plain squash succeeds"; then
    assert_log_has  "pr merge 42 --squash" "default uses --squash"
    assert_log_lacks "--admin"             "default does NOT use --admin"
fi

# --- --dry-run prints plain command on stdout, invokes no merge ---
if run_case "handover/x-slug" 0 "dry-run exits 0" -- --dry-run; then
    assert_out_has   "would squash-merge PR #42 on github" "dry-run prints plain squash-merge intent"
    assert_out_lacks "--admin"                             "dry-run command omits --admin"
    assert_log_lacks "pr merge"                            "dry-run invokes no real merge"
fi

# --- plain fails + admin authorized => retries WITH --admin, succeeds ---
STUB_PLAIN_FAIL=1 GH_ADMIN_MERGE_OK=1 \
    run_case "handover/x-slug" 0 "plain-fail + authorized retries admin"
assert_log_has "--admin" "authorized fallback used --admin"

# --- plain fails + admin NOT authorized => exit 4, never tries --admin ---
STUB_PLAIN_FAIL=1 \
    run_case "handover/x-slug" 4 "plain-fail + unauthorized exits 4"
assert_log_lacks "--admin" "unauthorized never attempts --admin"

# --- cosmetic worktree-held branch-delete error => exit 0 (no admin retry) ---
STUB_COSMETIC=1 \
    run_case "handover/x-slug" 0 "cosmetic branch-delete fail is exit 0"
assert_log_lacks "--admin" "cosmetic fail does not escalate to --admin"

# --- authorized --admin fallback itself fails (non-cosmetic) => exit 4 ---
STUB_PLAIN_FAIL=1 STUB_ADMIN_FAIL=1 GH_ADMIN_MERGE_OK=1 \
    run_case "handover/x-slug" 4 "admin fallback failure exits 4"
assert_log_has "--admin" "admin fallback was attempted before exit 4"

# --- authorized --admin fallback hits cosmetic delete error => exit 0 ---
STUB_PLAIN_FAIL=1 STUB_ADMIN_COSMETIC=1 GH_ADMIN_MERGE_OK=1 \
    run_case "handover/x-slug" 0 "admin fallback cosmetic-fail is exit 0"
assert_log_has "--admin" "admin fallback ran on cosmetic path"

# --- gh pr list failure must NOT report a clean no-op (HIMMEL-224 CR) ---
STUB_LIST_FAIL=1 \
    run_case "handover/x-slug" 4 "gh pr list failure exits 4 (not silent no-op)"
assert_log_lacks "pr merge" "no merge attempted when PR state is unknown"

# --- deterministic mergeability check (HIMMEL-1232, local git merge-tree) ---
# The old bounded poll (HIMMEL-179) is gone: forge_pr_mergeable now computes the
# conflict locally in one shot. The check reads base+head via
# `gh pr view <n> --json baseRefName,headRefOid` and runs git merge-tree.

# (a) clean branch (merge-tree MERGEABLE) => proceeds to merge.
if run_case "handover/x-slug" 0 "check: MERGEABLE merges"; then
    assert_log_has "pr view 42 --json baseRefName,headRefOid" "check queried base+head refs"
    assert_log_has "pr merge 42 --squash"                     "MERGEABLE proceeds to merge"
fi

# (b) real conflict (merge-tree CONFLICTING) => exit 4, no merge attempted.
if SETUP_MERGE_CONFLICT=1 \
    run_case "handover/x-slug" 4 "check: CONFLICTING exits 4"; then
    assert_log_lacks "pr merge" "CONFLICTING does not attempt merge"
fi

# (c) UNKNOWN (head SHA not resolvable locally — a tooling gap) => fails OPEN
#     and falls through to merge (never hard-block on a tool gap).
if STUB_MERGE_UNKNOWN=1 \
    run_case "handover/x-slug" 0 "check: UNKNOWN fails open to merge"; then
    assert_log_has "pr merge 42 --squash" "UNKNOWN still attempts merge"
fi

# (d) gh pr view (base+head read) itself fails => empty verdict => fails OPEN.
if STUB_MERGE_VIEW_FAIL=1 \
    run_case "handover/x-slug" 0 "check: gh view failure falls through to merge"; then
    assert_log_has "pr merge 42 --squash" "view failure still attempts merge"
fi

# --- HIMMEL-936: CR merge gate blocks before the mergeability check (exit 5) ---
# STUB_CR_BLOCK=1 arms the gate's pr-view metadata arm + the graphql arm so
# cr_merge_gate positively confirms an unresolved coderabbitai thread. The
# gate runs BEFORE the mergeability check, so neither the check's pr view nor
# `gh pr merge` is reached. Existing cases above stay green by design: their
# stub returns non-JSON for the gate's pr-view (headRefOid branch, STUB_CR_BLOCK
# unset), so cr_merge_gate degrades and fails open (plan-critic #4).
if STUB_CR_BLOCK=1 \
    run_case "handover/x-slug" 5 "CR-gate block exits 5 before check"; then
    assert_log_lacks "pr merge" "CR-gate block does not attempt merge"
    assert_err_has    "CR gate" "CR-gate block reports CR gate on stderr"
fi

# --- HIMMEL-1043: CI-green gate blocks AFTER the CR gate (exit 6) ---
# STUB_CI_BLOCK=1: CR gate passes (resolved coderabbit threads + a completed
# CodeRabbit check-run), but a non-CodeRabbit check-run ("tests") failed, so
# ci_green_gate blocks. Runs AFTER the CR gate (exit 5) and BEFORE the
# mergeability check, so neither the check's pr view nor `gh pr merge` is reached.
if STUB_CI_BLOCK=1 \
    run_case "handover/x-slug" 6 "CI-gate block exits 6 before check"; then
    assert_log_lacks "pr merge" "CI-gate block does not attempt merge"
    assert_err_has    "CI gate" "CI-gate block reports CI gate on stderr"
fi

# --- HIMMEL-1058: the merge is BOUND to the vetted head SHA ---
# STUB_ALL_GREEN=1: metadata resolves, threads are resolved, CodeRabbit's status
# is success, CI is green — so both gates pass and the merge actually runs. The
# TOCTOU fix is only real if `--match-head-commit <vetted sha>` reaches gh: a
# push landing between the gates and the merge must be REJECTED by GitHub rather
# than silently merged unvetted.
if STUB_ALL_GREEN=1 \
    run_case "handover/x-slug" 0 "all-green merges"; then
    # The flag must ride the SAME `pr merge` invocation (coderabbit-12) — an
    # independent "log contains --match-head-commit" check would also pass if the
    # flag appeared on some other call, which would bind nothing.
    if grep -E '^pr merge .*--match-head-commit abc123' "$LAST_GH_LOG" >/dev/null; then
        pass
    else
        fail "merge call itself carries --match-head-commit abc123 (log: $(cat "$LAST_GH_LOG"))"
    fi
    # The head must be READ before the gates run, or the value bound is not the
    # one the gates saw-or-newer (the whole HIMMEL-1058 ordering argument).
    head_ln=$(grep -n -- '--jq .headRefOid' "$LAST_GH_LOG" | head -1 | cut -d: -f1)
    # The gate's FIRST call is its metadata read (`pr view --json
    # number,headRefOid,url`), not the graphql/api calls that follow — matching
    # only the latter would let the head read slip behind the gate's own first
    # operation and still pass (coderabbit-16). Both are `pr view` lines; the
    # head read is the one carrying --jq.
    gate_ln=$(grep -n 'pr view .*--json number,headRefOid,url\|api graphql\|api repos' "$LAST_GH_LOG" | head -1 | cut -d: -f1)
    if [ -n "$head_ln" ] && { [ -z "$gate_ln" ] || [ "$head_ln" -lt "$gate_ln" ]; }; then
        pass
    else
        fail "head SHA is read before the first gate call (head@${head_ln:-none} gate@${gate_ln:-none})"
    fi
fi

# A head SHA that cannot be read means the merge cannot be bound — refuse (7)
# rather than fall back to an unbound merge.
if STUB_ALL_GREEN=1 STUB_HEAD_UNREADABLE=1 \
    run_case "handover/x-slug" 7 "unreadable head refuses to merge unbound"; then
    assert_log_lacks "pr merge" "unbound merge is never attempted"
    # It refuses BEFORE spending any gate call — the bind is a precondition, not
    # an afterthought (coderabbit-12).
    assert_log_lacks "api graphql" "unreadable head runs no CR gate"
    assert_log_lacks "api repos"   "unreadable head runs no CI gate"
fi

# --- summary ---
echo "  pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "PASS"
exit 0
