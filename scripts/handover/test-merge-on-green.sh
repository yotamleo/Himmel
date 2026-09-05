#!/usr/bin/env bash
# Tests for handover/merge-on-green.sh — the HIMMEL-1042 armed-chain auto-merge
# chokepoint. The wrapper has NO env seams for `gh`/`check-ci` (gate integrity,
# coderabbit): so each case runs a COPY of the script in a temp tree
# ($tmp/scripts/handover/merge-on-green.sh) with a stub check-ci at the fixed
# sibling path ($tmp/scripts/check-ci.sh) and a stub `gh` FIRST on PATH. Asserts
# the fail-closed gate sequence + that a real merge only ever fires with
# --squash + --match-head-commit <certified-sha>.
set -uo pipefail

# HIMMEL-1495 — an --automerge-armed launching shell carries ARMAUTOMERGE=1 +
# CR_MERGE_GATE_OK=1 by design; an ambient value in the operator's shell must
# not decide the result (the 34e/34f precedent in test-check-ci.sh,
# generalized). merge-on-green.sh gates on a truthy ARMAUTOMERGE
# (merge-on-green.sh:153), so an ambient =1 would make the no-opt-in refusal
# (case 1) read as opted-in. (Case 1's own inline `unset ARMAUTOMERGE` is
# retained; this is the startup defense-in-depth + the CR_MERGE_GATE_OK scrub
# for the day a sourced lib reads it.)
unset ARMAUTOMERGE CR_MERGE_GATE_OK

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOG="$SCRIPT_DIR/merge-on-green.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# run_mog <expected-exit> <test-name> [-- extra merge-on-green args...]
# Stub behavior controlled by env vars exported before the call:
#   STUB_STATE          initial PR state in the meta query. Default OPEN.
#   STUB_STATE_FAIL=1   the meta `gh pr view` exits 1 (API failure).
#   STUB_NO_PR=1        the meta `gh pr view` exits 1 with "no pull requests found".
#   STUB_PRIVATE        `gh repo view <nwo> --json isPrivate` value. Default true.
#                       Empty => undeterminable (fail closed).
#   STUB_NWO            the PR's owner/repo (in its url). Default owner/repo.
#   STUB_CWD_NWO        the CURRENT checkout's owner/repo. Default = STUB_NWO.
#   STUB_CWD_FAIL=1     `gh repo view --json nameWithOwner` (cwd) exits 1.
#   STUB_SHA            `headRefOid` in the meta query. Default a fixed fake sha.
#   STUB_BASE            `baseRefName` in the meta query. Default main.
#   STUB_HEAD_BRANCH     `headRefName` in the meta query (HIMMEL-1970 — the
#                        branch whose worktree is pruned after a confirmed
#                        merge). Default feat/stub-head (matches nothing).
#   MOG_CWD              Directory to run merge-on-green FROM. Default: the
#                        case's own temp dir (not a git repo), so the prune
#                        finds nothing. Prune cases point it at a fixture repo
#                        or at the fixture worktree itself.
#   STUB_DEFAULT_BRANCH  `defaultBranchRef.name` in the repo-meta query. Default main.
#   STUB_BASE_PREMERGE   `baseRefName` in the FIX-1 pre-merge re-query (fires
#                        after check-ci, before merging). Default = STUB_BASE.
#   STUB_DEFAULT_BRANCH_PREMERGE  `defaultBranchRef.name` in the FIX-1 pre-merge
#                        re-query. Default = STUB_DEFAULT_BRANCH.
#   STUB_PRIVATE_PREMERGE  `isPrivate` in the FIX-1 pre-merge re-verify
#                        (HIMMEL-1080 CR round-3 folds isPrivate into the
#                        pre-merge repo view). Default = STUB_PRIVATE. Set false
#                        to simulate a repo made public during the CI wait.
#   STUB_DEFAULT_BRANCH_NULL=1  the repo-meta query's defaultBranchRef is JSON
#                        null over the wire — runs the SCRIPT'S OWN --jq filter
#                        (captured from argv) through real jq against synthetic
#                        null JSON, so this proves the coalesce fix rather than
#                        a hand-picked stub string.
#   STUB_DEFAULT_BRANCH_PREMERGE_NULL=1  same, for the FIX-1 pre-merge query.
#   STUB_CI_RC          exit code of the stub check-ci. Default 0.
#   STUB_MERGE_FAIL=1   `gh pr merge` exits 1 (generic failure).
#   STUB_POST_STATE     PR state the post-merge re-query returns. Default MERGED.
#   STUB_POST_STATE_FAIL=1  the post-merge state re-query fails (indeterminate).
#   STUB_POST_HEAD      headRefOid the failure-recovery re-query
#                        (state,headRefOid,baseRefName) returns. Default =
#                        STUB_SHA (matches the certified sha, so existing tests
#                        see an unchanged head). Set it to a different value to
#                        simulate a concurrently-merged commit.
#   STUB_POST_BASE       baseRefName the failure-recovery re-query returns.
#                        Default = STUB_BASE (matches the authorized base, so
#                        existing tests see an unchanged base). Set it to a
#                        different value to simulate a concurrent retarget.
#   STUB_POST_OPEN_TIMES  the first N post-merge re-queries report OPEN before
#                        STUB_POST_STATE takes over (HIMMEL-1697) — a merge
#                        accepted server-side that only lands a moment later.
#                        Default 0 (the first read already reports the state).
#   NO_CHECK_CI=1       omit the stub check-ci (sibling path absent).
#   STUB_AUDIT_UNWRITABLE=1  point the audit sink at an unwritable path.
#   STUB_CLEAR_RC       exit code of the stub clear-cr-marker (HIMMEL-1346).
#                        Default 0.
#   STUB_NO_CLEARER=1   omit the stub clear-cr-marker (sibling path absent).
# After the run: $LAST_GH_LOG = stub gh argv log, $LAST_AUDIT = audit log,
# $LAST_CLEAR_LOG = stub clear-cr-marker argv log (empty = never invoked),
# $LAST_ERR = the run's captured stderr (HIMMEL-2227, 11k3 — the gutted-remove
# operator message is stderr-only, never the audit log).
LAST_GH_LOG=""; LAST_AUDIT=""; LAST_CLEAR_LOG=""; LAST_ERR=""
run_mog() {
    local expected="$1" name="$2"; shift 2
    [ "${1:-}" = "--" ] && shift
    local tmp; tmp=$(mktemp -d)
    local ghlog="$tmp/gh.log"; : > "$ghlog"
    local audit="$tmp/audit.log"
    [ "${STUB_AUDIT_UNWRITABLE:-0}" = "1" ] && audit="$tmp/nodir/audit.log"  # parent absent → unwritable

    # Copy the script into a temp tree so its fixed `../check-ci.sh` sibling
    # resolves to our stub — no CHECK_CI env override exists any more.
    mkdir -p "$tmp/scripts/handover" "$tmp/scripts/lib" "$tmp/bin"
    cp "$MOG" "$tmp/scripts/handover/merge-on-green.sh"
    # merge-on-green.sh now sources its HIMMEL-2227 in-use predicates from the
    # shared lib (../lib/worktree-inuse.sh, relative to its own SCRIPT_DIR) —
    # the copy must carry that sibling too.
    cp "$SCRIPT_DIR/../lib/worktree-inuse.sh" "$tmp/scripts/lib/worktree-inuse.sh"
    # HIMMEL-2380: merge-on-green now records the repo's CodeRabbit-availability
    # state on its audit lines, and reads it from this sibling. Without the copy
    # the source fails, CR_STATE falls back to `unknown`, and every cr= assertion
    # below would pass while testing nothing.
    cp "$SCRIPT_DIR/../lib/cr-available.sh" "$tmp/scripts/lib/cr-available.sh"
    if [ "${NO_CHECK_CI:-0}" != "1" ]; then
        printf '#!/usr/bin/env bash\nexit %s\n' "${STUB_CI_RC:-0}" > "$tmp/scripts/check-ci.sh"
        chmod +x "$tmp/scripts/check-ci.sh"
    fi

    # Stub the CR-marker chokepoint at ITS fixed sibling path (HIMMEL-1346),
    # exactly like check-ci above — the wrapper has no env seam for it either.
    # The stub records its argv, so a case can prove the merge path went THROUGH
    # clear-cr-marker.sh (never a raw `rm`) and with which branch.
    local clearlog="$tmp/clear.log"; : > "$clearlog"
    if [ "${STUB_NO_CLEARER:-0}" != "1" ]; then
        mkdir -p "$tmp/scripts/cr"
        # SC2016 is the point: "$*" / "$CLEAR_LOG" must reach the stub FILE
        # unexpanded, to be expanded when the wrapper runs it. It also appends a
        # PREFIXED line to the gh log, which is the suite's only ordering record
        # — that is what pins the clear to BEFORE the merge (11L).
        # shellcheck disable=SC2016
        printf '#!/usr/bin/env bash\necho "clear-cr-marker $*" >> "$GH_LOG"\necho "$*" >> "$CLEAR_LOG"\nexit %s\n' \
            "${STUB_CLEAR_RC:-0}" > "$tmp/scripts/cr/clear-cr-marker.sh"
        chmod +x "$tmp/scripts/cr/clear-cr-marker.sh"
    fi

    # Stub `gh`, FIRST on PATH (no GH_CMD seam). FAILS CLOSED (coderabbit-1): an
    # unsupported verb or an unrecognized --json query exits non-zero rather than
    # falling through to a silent success — otherwise a wrapper that grew a new gh
    # call would be "tested" against a stub that rubber-stamps anything.
    cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
verb="$1 $2"
repo_arg="${3:-}"
json=""
jqexpr=""
while [ $# -gt 0 ]; do case "$1" in --json) json="${2:-}";; --jq) jqexpr="${2:-}";; esac; shift; done
nwo="${STUB_NWO:-owner/repo}"
case "$verb" in
    "pr view")
        [ "${STUB_NO_PR:-0}" = "1" ] && { echo 'no pull requests found for branch "x"' >&2; exit 1; }
        [ "${STUB_STATE_FAIL:-0}" = "1" ] && { echo "gh: api error" >&2; exit 1; }
        case "$json" in
            "state,url,number,headRefOid,baseRefName,headRefName")
                # Consolidated meta query (HIMMEL-1080 adds baseRefName;
                # HIMMEL-1970 adds headRefName, LAST, for the post-merge
                # worktree prune):
                # state|url|number|headRefOid|baseRefName|headRefName.
                if [ "${STUB_META_5FIELD:-0}" = "1" ]; then
                    # Pre-HIMMEL-1970 shape: headRefName missing. The wrapper
                    # must refuse, not let head_branch collapse onto pr_base.
                    printf '%s|https://github.com/%s/pull/%s|%s|%s|%s' \
                        "${STUB_STATE-OPEN}" "$nwo" "${STUB_NUM:-77}" "${STUB_NUM:-77}" "${STUB_SHA-abc123def456}" "${STUB_BASE-main}"
                    exit 0
                fi
                printf '%s|https://github.com/%s/pull/%s|%s|%s|%s|%s' \
                    "${STUB_STATE-OPEN}" "$nwo" "${STUB_NUM:-77}" "${STUB_NUM:-77}" "${STUB_SHA-abc123def456}" "${STUB_BASE-main}" "${STUB_HEAD_BRANCH-feat/stub-head}" ;;
            "baseRefName")
                # FIX-1 pre-merge re-query (HIMMEL-1080 CR round-1, codex-adv):
                # a fresh baseRefName read right before merging, independent of
                # the consolidated meta query above. Defaults to STUB_BASE so
                # existing tests (no premerge override) see an unchanged base.
                # `-` (not `:-`) so an explicitly-empty STUB_BASE_PREMERGE is
                # preserved, letting a test simulate an empty pre-merge base
                # (fail-closed path) rather than silently defaulting (coderabbit).
                printf '%s' "${STUB_BASE_PREMERGE-${STUB_BASE-main}}" ;;
            "state,headRefOid,baseRefName")
                # Post-merge re-query — shared by BOTH the failure-recovery
                # path AND the success-path confirmation poll (codex-adv,
                # HIMMEL-1394): state PLUS the merged head and base, so either
                # path can tell "this run's sha merged onto the authorized
                # base" apart from both "a different commit merged
                # concurrently" and "the same sha merged onto a different
                # (retargeted) base". The plain "state"-only query this used
                # to be (pre-HIMMEL-1394 success-path fix) has no caller left
                # in merge-on-green.sh; removed rather than left dead.
                [ "${STUB_POST_STATE_FAIL:-0}" = "1" ] && { echo "gh: state query failed" >&2; exit 1; }
                # STUB_POST_OPEN_TIMES=N (HIMMEL-1697): the first N re-queries
                # report OPEN, the rest report STUB_POST_STATE — a merge that
                # was accepted server-side and only reflects a moment later.
                # Routed by call ORDER via the gh argv log (this call is already
                # appended at the top of the stub), same trick as `repo view`.
                if [ "${STUB_POST_OPEN_TIMES:-0}" != "0" ]; then
                    n=$(grep -c 'json state,headRefOid,baseRefName' "$GH_LOG" 2>/dev/null || echo 1)
                    if [ "${n:-1}" -le "${STUB_POST_OPEN_TIMES}" ]; then
                        printf 'OPEN %s %s' "${STUB_POST_HEAD:-${STUB_SHA-abc123def456}}" "${STUB_POST_BASE:-${STUB_BASE-main}}"
                        exit 0
                    fi
                fi
                printf '%s %s %s' "${STUB_POST_STATE:-MERGED}" "${STUB_POST_HEAD:-${STUB_SHA-abc123def456}}" "${STUB_POST_BASE:-${STUB_BASE-main}}" ;;
            comments)
                # HIMMEL-2383 after-report pending marker: the wrapper pipes
                # this raw JSON through a REAL jq --arg pass (gh's own --jq
                # has no --arg support), so this must be realistic
                # {"comments":[...]} shape, not a pre-filtered count. A
                # matching comment embeds 'head: <STUB_SHA>' — the wrapper's
                # jq filter requires that exact head-SHA binding
                # (HIMMEL-2383 round-2 CR finding codex-5). Default: no
                # comments at all (no after-report posted yet).
                if [ "${STUB_AFTER_REPORT_SUMMARIES:-0}" != "0" ]; then
                    printf '{"comments":[{"body":"== Summary ==\\n head: %s\\n PASS: 5\\n FAIL: 0\\n"}]}' \
                        "${STUB_SHA-abc123def456}"
                else
                    printf '{"comments":[]}'
                fi ;;
            *) echo "gh stub: unhandled 'pr view' query: --json '$json'" >&2; exit 90 ;;
        esac
        ;;
    "repo view")
        # isPrivate + defaultBranchRef are queried TOGETHER (HIMMEL-1080 folds
        # the base-branch guard into the SAME query, no extra round-trip) and
        # keyed off the repo POSITIONAL ($3) — the PR's own repo, not cwd
        # (codex-1). nameWithOwner (no positional) = the CURRENT checkout for
        # the same-repo binding (codex-adv-2).
        case "$json" in
            isPrivate,defaultBranchRef)
                if [ -z "$jqexpr" ]; then
                    echo "gh stub: 'repo view' isPrivate,defaultBranchRef missing required --jq expression" >&2
                    exit 93
                fi
                # (CodeRabbit) Assert the positional repo arg — a regression
                # back to a cwd-scoped query would otherwise pass silently.
                if [ "$repo_arg" != "$nwo" ]; then
                    echo "gh stub: 'repo view' isPrivate,defaultBranchRef queried '$repo_arg', expected the PR repo '$nwo'" >&2
                    exit 92
                fi
                # This shape is queried TWICE per run — guard 2b (query time)
                # and the FIX-1 pre-merge re-verify (HIMMEL-1080 CR round-3 folds
                # isPrivate into the pre-merge repo view). Route by call ORDER via
                # the gh argv log: 1st occurrence = guard 2b, 2nd = pre-merge.
                # This call is already appended to GH_LOG (top of stub), so the
                # match count is 1 on the first call, 2 on the second.
                n=$(grep -c 'isPrivate,defaultBranchRef' "$GH_LOG" 2>/dev/null || echo 1)
                if [ "${n:-1}" -le 1 ]; then
                    # guard 2b (query time). defaultBranchRef is NULLABLE
                    # (CodeRabbit): feed synthetic null JSON through the SCRIPT'S
                    # OWN --jq filter (captured above) via real jq, proving the
                    # coalesce fix in merge-on-green.sh rather than a stub string.
                    if [ "${STUB_DEFAULT_BRANCH_NULL:-0}" = "1" ]; then
                        printf '{"isPrivate":%s,"defaultBranchRef":null}' "${STUB_PRIVATE-true}" | jq -r "$jqexpr"
                    else
                        printf '%s|%s' "${STUB_PRIVATE-true}" "${STUB_DEFAULT_BRANCH-main}"
                    fi
                else
                    # FIX-1 pre-merge re-verify (privacy + default branch both
                    # re-read). STUB_PRIVATE_PREMERGE / STUB_DEFAULT_BRANCH_PREMERGE
                    # default to their guard-2b values so tests that don't
                    # override see an unchanged repo.
                    if [ "${STUB_DEFAULT_BRANCH_PREMERGE_NULL:-0}" = "1" ]; then
                        printf '{"isPrivate":%s,"defaultBranchRef":null}' "${STUB_PRIVATE_PREMERGE:-${STUB_PRIVATE-true}}" | jq -r "$jqexpr"
                    else
                        printf '%s|%s' "${STUB_PRIVATE_PREMERGE:-${STUB_PRIVATE-true}}" "${STUB_DEFAULT_BRANCH_PREMERGE:-${STUB_DEFAULT_BRANCH-main}}"
                    fi
                fi ;;
            nameWithOwner)
                # No positional — this is the CURRENT checkout query
                # (codex-adv-2), not the PR's repo. Do NOT add a repo_arg check.
                [ "${STUB_CWD_FAIL:-0}" = "1" ] && { echo "gh: api error" >&2; exit 1; }
                printf '%s' "${STUB_CWD_NWO:-${STUB_NWO:-owner/repo}}" ;;
            *) echo "gh stub: unhandled 'repo view' query: --json '$json'" >&2; exit 90 ;;
        esac
        ;;
    "pr merge")
        [ "${STUB_MERGE_FAIL:-0}" = "1" ] && { echo "merge conflict / head moved" >&2; exit 1; }
        echo "merged"
        ;;
    *) echo "gh stub: unsupported command: $*" >&2; exit 90 ;;
esac
exit 0
STUB
    chmod +x "$tmp/bin/gh"

    local err rc
    # cwd matters since HIMMEL-1970: the post-merge prune reads `git worktree
    # list` from the checkout the script runs in. Default to the (non-repo)
    # temp dir so the suite is hermetic — it must never see, let alone remove,
    # a worktree of the real himmel checkout. MOG_CWD points a case at its own
    # throwaway fixture repo.
    # HIMMEL-1953: the confirmation poll's `sleep 2` never runs for real here —
    # a test that sleeps is a test that can hang.
    GH_LOG="$ghlog" CLEAR_LOG="$clearlog" MERGE_ON_GREEN_LOG="$audit" PATH="$tmp/bin:$PATH" \
          MERGE_ON_GREEN_SLEEP_CMD=: \
          CR_APP="${MOG_CR_APP:-}" \
          bash -c 'cd "$1" || exit 1; shift; exec bash "$@"' _ "${MOG_CWD:-$tmp}" \
          "$tmp/scripts/handover/merge-on-green.sh" "$@" >/dev/null 2>"$tmp/err"
    rc=$?
    err=$(cat "$tmp/err" 2>/dev/null)

    LAST_GH_LOG="$ghlog"; LAST_AUDIT="$audit"; LAST_CLEAR_LOG="$clearlog"; LAST_ERR="$err"
    if [ "$rc" -eq "$expected" ]; then
        pass
    else
        fail "$name — expected exit $expected, got $rc (err: ${err:-<none>})"
    fi
}

assert_gh_has() {
    if grep -qF -- "$2" "$LAST_GH_LOG"; then pass; else fail "$1 (gh log lacks '$2')"; fi
}
assert_gh_lacks() {
    if grep -qF -- "$2" "$LAST_GH_LOG"; then fail "$1 (gh log unexpectedly has '$2')"; else pass; fi
}
assert_audit_has() {
    if grep -qF -- "$2" "$LAST_AUDIT" 2>/dev/null; then pass; else fail "$1 (audit log lacks '$2')"; fi
}
assert_audit_lacks() {
    if grep -qF -- "$2" "$LAST_AUDIT" 2>/dev/null; then fail "$1 (audit log unexpectedly has '$2')"; else pass; fi
}
assert_err_has() {
    if grepq "$LAST_ERR" -F -- "$2"; then pass; else fail "$1 (stderr lacks '$2')"; fi
}
# HIMMEL-1346 — did the run go through the clear-cr-marker chokepoint, and with
# what argv? An EMPTY log is the assertion that it was never invoked.
assert_clear_has() {
    if grep -qF -- "$2" "$LAST_CLEAR_LOG" 2>/dev/null; then pass; else fail "$1 (clear-cr-marker log lacks '$2'; got: $(cat "$LAST_CLEAR_LOG" 2>/dev/null))"; fi
}
assert_clear_not_invoked() {
    if [ -s "$LAST_CLEAR_LOG" ]; then fail "$1 (clear-cr-marker was invoked: $(cat "$LAST_CLEAR_LOG"))"; else pass; fi
}
# Scope merge-flag assertions to the `pr merge` invocation itself (coderabbit-1).
# Searching the whole GH_LOG would let a flag appearing in ANY other gh call
# satisfy an assertion about how the MERGE was invoked — which is the one thing
# these assertions exist to prove.
merge_line() { grep -E '^pr merge( |$)' "$LAST_GH_LOG" 2>/dev/null; }
assert_merge_has() {
    if merge_line | grep -qF -- "$2"; then pass
    else fail "$1 (pr merge invocation lacks '$2'; got: $(merge_line 2>/dev/null || echo '<no pr merge call>'))"; fi
}
assert_merge_lacks() {
    if merge_line | grep -qF -- "$2"; then fail "$1 (pr merge invocation unexpectedly has '$2'; got: $(merge_line))"
    else pass; fi
}
# Assert a post-merge state RE-QUERY happened (coderabbit). A literal
# "pr view --json state" would also match the initial metadata query
# (`--json state,url,number,headRefOid`) as a substring, so the assertion would
# pass even with post-merge confirmation removed entirely — vacuously guarding
# the one behavior it exists to prove. Anchor on a word boundary after `state`
# so only the state-ONLY or state+headRefOid re-queries match — never the
# initial metadata query (which lists FOUR more fields after `state,`).
# `state,headRefOid,baseRefName` is the failure-recovery re-query (codex-adv,
# HIMMEL-1394); `state` alone is the success-path confirmation poll — both are
# legitimate post-merge re-queries this assertion accepts.
# The re-query must be PINNED to the resolved PR number + repo (HIMMEL-1694):
# a selector-less `pr view` resolves from the current branch, which is wrong
# after a post-merge checkout switch or from a cwd that is not the PR's tree.
assert_state_requery() {
    if grep -Eq '^pr view [0-9]+ --repo [^ ]+ --json state(,headRefOid,baseRefName)?( |$)' "$LAST_GH_LOG"; then pass
    else fail "$1 (no PINNED post-merge 'pr view <num> --repo <nwo> --json state[,headRefOid,baseRefName]' re-query found)"; fi
}
# Exact resolved identity (coderabbit, #1758): the pin must name THIS PR's
# number and THIS PR's repo, for the pre-merge baseRefName re-query as well as
# the post-merge state re-query — a regression that targets another PR, or
# drops the pin from one of the two, must fail.
assert_pinned_pr_view() {
    if grep -qF -- "pr view 77 --repo acme/private-repo --json $2" "$LAST_GH_LOG"; then pass
    else fail "$1 (no pinned 'pr view 77 --repo acme/private-repo --json $2' call found)"; fi
}

echo "== merge-on-green.sh tests =="

# HIMMEL-1495 hermeticity probe — when this suite re-execs itself under the
# armed bypass env (see the guard at the end), short-circuit here. The startup
# unset above must have already scrubbed the parent's exported ARMAUTOMERGE=1,
# so the no-opt-in refusal STILL fires (exit 10). Exit 0 = scrub held; exit 1 =
# ARMAUTOMERGE leaked and the wrapper read as opted-in (not exit 10). Relies on
# the startup scrub (does NOT re-unset), so it guards THAT line. One run_mog.
if [ "${HIMMEL_1495_SELF:-0}" = "1" ]; then
    _probe_fail_before=$FAIL
    STUB_NO_PR=1 run_mog 10 "armed-env scrubbed: no-opt-in still refuses"
    [ "$FAIL" = "$_probe_fail_before" ] && exit 0 || exit 1
fi

# 1. No opt-in → refuse (exit 10). Unset in the PARENT shell (no subshell) so
# pass()/fail() land in the top-level tally (coderabbit-1).
unset ARMAUTOMERGE
run_mog 10 "no ARMAUTOMERGE → exit 10"
export ARMAUTOMERGE=1

# 2. Opted in, no PR (empty state) → clean no-op (exit 0).
STUB_STATE="" run_mog 0 "empty PR state → exit 0 nothing-to-merge"

# 3. PR query fails (auth/network) → refuse (exit 13), NOT a silent no-op.
STUB_STATE_FAIL=1 run_mog 13 "gh pr view auth/network failure → exit 13 (not no-op)"

# 3b. gh 'no pull requests found' → clean no-op (exit 0), NOT a refusal.
STUB_NO_PR=1 run_mog 0 "gh 'no pull requests found' → exit 0 nothing-to-merge"
assert_gh_lacks "no-PR: no merge attempted" "pr merge"

# 4. PR OPEN but repo is public → fail-closed refuse (exit 12), no merge.
STUB_PRIVATE=false run_mog 12 "public repo → exit 12"
assert_gh_lacks "public repo: no merge attempted" "pr merge"

# 5. isPrivate undeterminable (empty) → fail closed (exit 12).
STUB_PRIVATE="" run_mog 12 "undeterminable privacy → exit 12 fail-closed"

# 5b. Cross-repo selector: PR repo != current checkout → refuse (exit 12),
# no merge (codex-adv-2 — standing auth must not reach other private repos).
STUB_NWO="acme/other-private" STUB_CWD_NWO="acme/this-repo" run_mog 12 "cross-repo PR → exit 12"
assert_gh_lacks "cross-repo: no merge attempted" "pr merge"

# 5c. Cannot resolve cwd repo → fail closed (exit 12).
STUB_CWD_FAIL=1 run_mog 12 "unresolvable cwd repo → exit 12 fail-closed"

# 6. Cannot read head SHA → refuse (exit 13).
STUB_SHA="" run_mog 13 "empty head SHA → exit 13"

# 7. check-ci not found → refuse (exit 14).
NO_CHECK_CI=1 run_mog 14 "missing check-ci → exit 14"

# 8. check-ci non-green (exit 3) → refuse (exit 14), no merge.
STUB_CI_RC=3 run_mog 14 "check-ci exit 3 → exit 14"
assert_gh_lacks "non-green: no merge attempted" "pr merge"

# 9. All gates pass → merge (exit 0) with --squash + --match-head-commit <sha>.
STUB_SHA="feedface99" STUB_NWO="acme/private-repo" run_mog 0 "all gates pass → merged"
assert_merge_has "merge uses --squash"              "--squash"
assert_merge_has "merge pins the certified head SHA" "--match-head-commit feedface99"
# HIMMEL-1679: no --delete-branch — every branch is worktree-held, so gh's local
# delete failed on every real merge; the repo's deleteBranchOnMerge + /clean own
# cleanup. HIMMEL-1694: the merge is pinned to the resolved PR number + repo.
assert_merge_lacks "merge does not ask gh to delete the branch" "--delete-branch"
assert_merge_has "merge pinned to the resolved PR number + repo" "pr merge 77 --repo acme/private-repo"
assert_pinned_pr_view "pre-merge base re-query is pinned to THIS PR's number + repo" "baseRefName"
assert_pinned_pr_view "success-path confirmation poll is pinned to THIS PR's number + repo" "state,headRefOid,baseRefName"
# codex-1 regression: the privacy check targets the PR's OWN repo, not cwd.
assert_gh_has  "privacy check scoped to the PR repo" "repo view acme/private-repo"
assert_audit_has "audit records MERGING intent"   "MERGING"
assert_audit_has "audit records MERGED + sha"     "MERGED"
assert_audit_has "audit records the certified sha" "sha=feedface99"

# 9b. Base-branch guard (HIMMEL-1080): PR based on the repo's default branch
# still reaches the merge — the guard is additive, not a behavior change for
# the (common) approved-target case.
STUB_SHA="basecheck01" STUB_BASE="main" STUB_DEFAULT_BRANCH="main" \
    run_mog 0 "PR on default branch → merged"
assert_merge_has "base-branch-ok merge pins the certified sha" "--match-head-commit basecheck01"

# 9c. Base-branch guard (HIMMEL-1080): PR based on any OTHER branch is refused
# (exit 12), no merge — the standing allow-rule only covers PRs against the
# repo's default branch (inject-initiative.sh:236: "squash-merge to PRIVATE
# main").
STUB_BASE="some/other-branch" STUB_DEFAULT_BRANCH="main" \
    run_mog 12 "PR on non-default base branch → exit 12"
assert_gh_lacks "wrong-base: no merge attempted" "pr merge"
assert_audit_has "wrong-base audits the refusal reason" "reason=wrong-base-branch"
assert_audit_has "wrong-base audit records the pr base" "pr_base=some/other-branch"
assert_audit_has "wrong-base audit records the authorized branch" "authorized_branch=main"

# 9d. Base-branch guard fail-closed: an undeterminable repo default branch
# refuses (exit 12) rather than waving the merge through.
STUB_DEFAULT_BRANCH="" run_mog 12 "undeterminable default branch → exit 12 fail-closed"
assert_gh_lacks "undeterminable-default: no merge attempted" "pr merge"
assert_audit_has "undeterminable-default audits the reason" "reason=base-branch-undeterminable"

# 9e. Base-branch retarget race (HIMMEL-1080 CR round-1, codex-adv [high]): the
# PR was on the default branch at the gate (guard 2c) but got RETARGETED during
# check-ci.sh's watch window — the head SHA never moved (gh allows editing a
# PR's base without touching its head), so --match-head-commit alone would not
# catch it. The pre-merge re-query (FIX-1) must catch the retarget and refuse
# (exit 12); the merge must never fire.
STUB_SHA="retarget01" STUB_BASE="main" STUB_DEFAULT_BRANCH="main" \
    STUB_BASE_PREMERGE="some/other-branch" \
    run_mog 12 "base retargeted after the gate → exit 12"
assert_gh_lacks "retargeted-base: no merge attempted" "pr merge"
assert_audit_has "retargeted-base audits the reason" "reason=base-branch-changed"
assert_audit_has "retargeted-base audit records the base certified at the gate" "pr_base_at_gate=main"
assert_audit_has "retargeted-base audit records the new base" "pr_base_now=some/other-branch"

# 9e2. Repository made PUBLIC during the CI wait (HIMMEL-1080 CR round-3,
# coderabbit [major]): the repo passed the private-only boundary at guard 2b
# but was flipped public during check-ci.sh's watch window — the same staleness
# class as the base retarget above. The pre-merge re-verify folds isPrivate into
# its repo view and must refuse (exit 12); the merge must never fire.
STUB_SHA="pubrace01" STUB_PRIVATE=true STUB_PRIVATE_PREMERGE=false \
    run_mog 12 "repo made public during the CI wait → exit 12"
assert_gh_lacks "public-race: no merge attempted" "pr merge"
assert_audit_has "public-race audits the pre-merge privacy reason" "reason=not-private-premerge"

# 9e3. Empty pre-merge baseRefName (HIMMEL-1080 CR round-3, coderabbit): a fresh
# baseRefName that comes back EMPTY right before merging is undeterminable →
# refuse (exit 12) fail-closed, never default silently. The stub preserves an
# explicitly-empty STUB_BASE_PREMERGE (`-`, not `:-`) so this path is reachable.
STUB_SHA="emptybase01" STUB_BASE_PREMERGE="" \
    run_mog 12 "empty pre-merge base → exit 12 fail-closed"
assert_gh_lacks "empty-premerge-base: no merge attempted" "pr merge"
assert_audit_has "empty-premerge-base audits undeterminable" "reason=base-branch-undeterminable"

# External `jq` availability (CodeRabbit round-2, HIMMEL-1080): the two null-
# coalesce cases below feed synthetic null JSON through the SCRIPT'S OWN --jq
# filter via real jq — proving the coalesce fix in merge-on-green.sh itself
# rather than a hand-picked stub string. jq is NOT an established dependency
# of this repo (no standalone `jq` anywhere under scripts/ — the many `--jq`
# are gh's OWN embedded jq, not the external binary). On a machine without jq
# SKIP those cases cleanly instead of silently breaking: this suite has no
# skip counter, so a SKIP line is not counted as pass or fail. Behaviour is
# unchanged when jq IS installed.
have_jq=0; command -v jq >/dev/null 2>&1 && have_jq=1

# 9f. Nullable defaultBranchRef at guard 2b/2c (CodeRabbit [minor]): a repo API
# response with defaultBranchRef: null must be coalesced in the script's OWN
# --jq filter to "" (undeterminable), not jq's literal "null" string sliding
# past -z and mislabeling as wrong-base-branch.
if [ "$have_jq" = "1" ]; then
    STUB_DEFAULT_BRANCH_NULL=1 run_mog 12 "null defaultBranchRef at the gate → exit 12 undeterminable"
    assert_gh_lacks "null-default-branch: no merge attempted" "pr merge"
    assert_audit_has "null-default-branch audits undeterminable, not wrong-base" "reason=base-branch-undeterminable"
else
    echo "  SKIP: jq not installed — null-defaultBranchRef-at-gate case (CodeRabbit, HIMMEL-1080)"
fi

# 9g. Same nullable-coalesce fix applied to the FIX-1 pre-merge re-query.
if [ "$have_jq" = "1" ]; then
    STUB_DEFAULT_BRANCH_PREMERGE_NULL=1 run_mog 12 "null defaultBranchRef at the pre-merge re-query → exit 12 undeterminable"
    assert_gh_lacks "null-default-branch-premerge: no merge attempted" "pr merge"
    assert_audit_has "null-default-branch-premerge audits undeterminable" "reason=base-branch-undeterminable"
else
    echo "  SKIP: jq not installed — null-defaultBranchRef-pre-merge case (CodeRabbit, HIMMEL-1080)"
fi

# 10. --dry-run: gates pass but NO merge fires.
run_mog 0 "dry-run passes gates, no merge" -- --dry-run
assert_gh_lacks  "dry-run does not merge"   "pr merge"
assert_audit_has "dry-run audits DRYRUN"    "DRYRUN"

# 11. gh pr merge fails (head moved / conflict) and the PR stays OPEN through the
# bounded confirmation poll → still fail-closed exit 15, but classified
# INDETERMINATE, not REFUSED (HIMMEL-1697): a merge accepted server-side and
# reported as failed can still land, so "not merged" is not proven here.
STUB_MERGE_FAIL=1 STUB_POST_STATE=OPEN run_mog 15 "merge failure + PR OPEN → exit 15 indeterminate"
assert_state_requery "failed merge re-queries PR state"
assert_audit_has "unproven merge outcome is INDETERMINATE" "INDETERMINATE reason=merge-pending-unconfirmed"
assert_audit_lacks "unproven merge outcome is not claimed as a refusal" "REFUSED"

# 11b. gh exited non-zero but the PR is MERGED at the certified sha/base →
# success (exit 0), audited with the gh exit for the record. (Historically the
# worktree-held local-branch delete, PR #1466 / HIMMEL-1679 — that cause is gone
# with --delete-branch, but any post-merge gh failure takes this path.)
STUB_SHA="cafe01" STUB_MERGE_FAIL=1 STUB_POST_STATE=MERGED run_mog 0 "gh rc!=0 + PR MERGED → exit 0"
assert_state_requery "gh-rc!=0 path re-queries PR state (pinned)"
assert_audit_has "gh-rc!=0 path records MERGED" "MERGED"
assert_audit_has "gh-rc!=0 audit names the gh exit" "gh-exit=1"
assert_audit_lacks "gh-rc!=0 audit carries no cleanup-failed record" "cleanup-failed"
# HIMMEL-1970: the recovery path prunes too — here from a non-repo cwd, so the
# outcome is "no-repo", but the field must be on the line.
assert_audit_has "gh-rc!=0 path records a prune outcome" "prune="
assert_audit_lacks "gh-rc!=0 merge is not recorded as refused" "REFUSED"

# 11c. HIMMEL-1697 — the case the single re-query got WRONG: gh reported a
# failure for a request that was actually accepted (queued behind branch
# protection / a lost response), so the PR reads OPEN first and MERGED a moment
# later. The bounded poll must see the landing and credit it (exit 0), where the
# old one-shot re-query reported REFUSED.
STUB_SHA="pollmerge01" STUB_MERGE_FAIL=1 STUB_POST_OPEN_TIMES=1 STUB_POST_STATE=MERGED \
    run_mog 0 "gh rc!=0 + OPEN then MERGED on a later poll → exit 0"
assert_audit_has "late-landing merge is credited" "MERGED repo="
assert_audit_has "late-landing merge names the gh exit" "gh-exit=1"
assert_audit_lacks "late-landing merge is not reported as indeterminate" "INDETERMINATE"

# 11c2. If the state re-query itself fails, the outcome is indeterminate rather
# than falsely classified as either MERGED or REFUSED.
STUB_MERGE_FAIL=1 STUB_POST_STATE_FAIL=1 run_mog 15 "merge failure + state query failure → indeterminate exit 15"
assert_audit_has "state-query failure records indeterminate outcome" "INDETERMINATE reason=merge-state-query-failed"
assert_audit_lacks "indeterminate outcome is not recorded as refused" "REFUSED"

# 11c3. gh's own merge call failed (so --match-head-commit never confirmed
# $sha) but the PR reports MERGED at a DIFFERENT head — a concurrent actor
# merged a different commit in the gap. Must NOT be credited to this run
# (codex-adv review, HIMMEL-1394).
STUB_SHA="cafe01" STUB_MERGE_FAIL=1 STUB_POST_STATE=MERGED STUB_POST_HEAD="deadbeef" \
    run_mog 15 "merge failure + PR MERGED at a different head → exit 15, not credited"
assert_audit_has "head-mismatch records the mismatch reason" "REFUSED reason=merge-state-head-mismatch"
assert_audit_has "head-mismatch audit names the certified sha" "sha=cafe01"
assert_audit_has "head-mismatch audit names the merged head" "merged_head=deadbeef"
assert_audit_lacks "head-mismatch is not recorded as MERGED" "MERGED repo="

# 11c4. gh's own merge call failed, and the PR reports MERGED with the SAME
# certified head — but landed on a DIFFERENT base than the one guard 3b
# re-verified (a concurrent `gh pr edit --base` retarget, which does not move
# the head). Must NOT be credited to this run (codex-adv review, HIMMEL-1394).
STUB_MERGE_FAIL=1 STUB_POST_STATE=MERGED STUB_POST_BASE="side-branch" \
    run_mog 15 "merge failure + PR MERGED at the certified sha but a different base → exit 15, not credited"
assert_audit_has "base-mismatch records the mismatch reason" "REFUSED reason=merge-state-base-mismatch"
assert_audit_has "base-mismatch audit names the authorized base" "authorized_base=main"
assert_audit_has "base-mismatch audit names the merged base" "merged_base=side-branch"
assert_audit_lacks "base-mismatch is not recorded as MERGED" "MERGED repo="

# 11d. Audit sink not writable → refuse BEFORE merging (exit 16), no merge.
STUB_AUDIT_UNWRITABLE=1 run_mog 16 "unwritable audit sink → exit 16"
assert_gh_lacks "unwritable-audit: no merge attempted" "pr merge"

# 11e. gh ACCEPTS the merge (rc 0) but the PR never reports MERGED → exit 15
# (coderabbit): a zero rc is "accepted", not "merged" — under a merge queue the
# PR can sit queued. exit 0 must mean MERGED. CLOSED (not OPEN) is used here so
# the confirmation poll breaks on the first read instead of waiting out its
# full budget; the OPEN/queued case walks the same branch after the timeout.
STUB_POST_STATE=CLOSED run_mog 15 "merge accepted but PR not MERGED → exit 15"
assert_audit_has "unconfirmed merge audits the refusal" "reason=merge-unconfirmed"
assert_state_requery "success path confirms PR state"

# 11f. gh ACCEPTS the merge (rc 0, e.g. queue admission), and the PR reports
# MERGED — but at a DIFFERENT head than the certified sha. A concurrent actor
# merged a different commit while this run's admission sat queued. Must NOT
# be credited (codex-adv review, HIMMEL-1394 — the success-path analog of 11c3).
STUB_SHA="cafe01" STUB_POST_STATE=MERGED STUB_POST_HEAD="deadbeef" \
    run_mog 15 "merge accepted + PR MERGED at a different head → exit 15, not credited"
assert_audit_has "success-path head-mismatch records the mismatch reason" "REFUSED reason=merge-state-head-mismatch"
assert_audit_has "success-path head-mismatch audit names the certified sha" "sha=cafe01"
assert_audit_has "success-path head-mismatch audit names the merged head" "merged_head=deadbeef"
assert_audit_lacks "success-path head-mismatch is not recorded as MERGED" "MERGED repo="

# 11g. gh ACCEPTS the merge (rc 0), and the PR reports MERGED at the certified
# head — but on a DIFFERENT base than guard 3b re-verified. A concurrent
# `gh pr edit --base` retarget while queued. Must NOT be credited (codex-adv
# review, HIMMEL-1394 — the success-path analog of 11c4).
STUB_POST_STATE=MERGED STUB_POST_BASE="side-branch" \
    run_mog 15 "merge accepted + PR MERGED at the certified sha but a different base → exit 15, not credited"
assert_audit_has "success-path base-mismatch records the mismatch reason" "REFUSED reason=merge-state-base-mismatch"
assert_audit_has "success-path base-mismatch audit names the authorized base" "authorized_base=main"
assert_audit_has "success-path base-mismatch audit names the merged base" "merged_base=side-branch"
assert_audit_lacks "success-path base-mismatch is not recorded as MERGED" "MERGED repo="

# --- 11h..11k. HIMMEL-1970 post-merge worktree prune ------------------------
# A confirmed merge prunes the ONE local worktree checked out on the PR's head
# branch, so a merged ticket's tree never outlives its PR. Fixture: a real
# throwaway repo + a real worktree per case (never the himmel checkout — see
# run_mog's cwd note). Every case must still exit 0: a prune that cannot happen
# is reported, never escalated.
mk_prune_fixture() {
    # echoes: <repo> <worktree> <branch-tip-sha>
    local root branch="feat/mog-prune" repo wt
    root=$(mktemp -d)
    repo="$root/repo"
    git init -q --initial-branch=main "$repo" 2>/dev/null || {
        git init -q "$repo"; git -C "$repo" symbolic-ref HEAD refs/heads/main || true
    }
    git -C "$repo" config user.email t@test.com
    git -C "$repo" config user.name t
    printf 'base\n' > "$repo/README"
    git -C "$repo" add README
    git -C "$repo" commit -q -m base
    git -C "$repo" branch -m main 2>/dev/null || true
    wt="$root/wt"
    git -C "$repo" worktree add -q "$wt" -b "$branch" >/dev/null 2>&1
    printf '%s\n' "$branch" > "$wt/work.txt"
    git -C "$wt" add work.txt
    git -C "$wt" commit -q -m work
    printf '%s %s %s\n' "$repo" "$wt" "$(git -C "$repo" rev-parse "$branch")"
}
prune_branch_gone() { ! git -C "$1" rev-parse --quiet --verify refs/heads/feat/mog-prune >/dev/null 2>&1; }
# wt_list_has <repo> <path> — does `git worktree list --porcelain` in <repo>
# still carry a row for <path>? Normalizes both sides via cd+pwd (the same
# trick merge-on-green.sh's own worktree_intact uses) because on this
# platform the porcelain output prints a DIFFERENT but equivalent spelling of
# the path (Windows-style C:/... vs POSIX /c/...) than a plain string compare
# would expect.
wt_list_has() {
    local repo="$1" path="$2" path_pwd line wt wt_pwd
    path_pwd=$(cd "$path" 2>/dev/null && pwd) || path_pwd="$path"
    while IFS= read -r line; do
        case "$line" in
            "worktree "*)
                wt="${line#worktree }"
                wt_pwd=$(cd "$wt" 2>/dev/null && pwd) || wt_pwd="$wt"
                [ "$wt_pwd" = "$path_pwd" ] && return 0
                ;;
        esac
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
    return 1
}

# 11g2. A metadata line missing the headRefName field is malformed → exit 13,
# no merge. Without the shape check head_branch silently becomes pr_base and is
# handed to the prune as a branch name.
STUB_META_5FIELD=1 run_mog 13 "5-field meta (no headRefName) → exit 13"
assert_gh_lacks "malformed meta: no merge attempted" "pr merge"
assert_audit_has "malformed meta is audited" "REFUSED reason=malformed-meta"

# 11h. Clean merged worktree, invoked from the PRIMARY checkout → removed,
# branch deleted, exit still 0. Also the negative control for the HIMMEL-2227
# in-use probe: nothing holds this tree, so the rename probe must not block a
# legitimate prune.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "merged + clean worktree → pruned, exit 0"
if [ -d "$P_WT" ]; then fail "11h: merged worktree was not removed"; else pass; fi
if prune_branch_gone "$P_REPO"; then pass; else fail "11h: merged branch was not deleted"; fi
assert_audit_has "11h: audit records the prune outcome" "prune=removed branch=deleted"

# 11i. Dirty worktree → plain `git worktree remove` refuses (never --force), the
# tree survives INTACT, and the merge is still a success. NEGATIVE CONTROL for
# HIMMEL-2227: `[ -d "$P_WT" ]` alone is not enough here — a GUTTED tree (the
# HIMMEL-2227 wreck) also satisfies that check, which is exactly the blind spot
# this ticket closes. Assert the tree is actually whole, not just present.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
printf 'uncommitted\n' >> "$P_WT/work.txt"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "merged + dirty worktree → kept, exit 0"
if [ -d "$P_WT" ]; then pass; else fail "11i: dirty worktree was destroyed"; fi
if [ -e "$P_WT/.git" ]; then pass; else fail "11i: dirty worktree's .git is gone (gutted, not kept)"; fi
if [ -f "$P_WT/work.txt" ] && grep -qF "uncommitted" "$P_WT/work.txt"; then
    pass
else
    fail "11i: dirty worktree's uncommitted work did not survive"
fi
if wt_list_has "$P_REPO" "$P_WT"; then
    pass
else
    fail "11i: dirty worktree's 'git worktree list' row is gone"
fi
if prune_branch_gone "$P_REPO"; then fail "11i: branch deleted despite a kept worktree"; else pass; fi
assert_audit_has "11i: audit records the refusal" "prune=dirty-kept"

# 11j. Invoked FROM the worktree it just merged → deferred, never removed out
# from under the caller.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
MOG_CWD="$P_WT" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "merged from inside the worktree → deferred, exit 0"
if [ -d "$P_WT" ]; then pass; else fail "11j: the caller's own cwd was removed"; fi
assert_audit_has "11j: audit records the deferral" "prune=own-cwd-deferred"

# 11k. A commit pushed after the squash merge (tip != certified sha) keeps the
# tree — clean-garden's exact-head-match rule, and what makes the branch -D
# fallback in 11h lossless.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
printf 'post-merge\n' >> "$P_WT/work.txt"
git -C "$P_WT" commit -q -am "post-merge work"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "merged but tip moved → kept, exit 0"
if [ -d "$P_WT" ]; then pass; else fail "11k: worktree with post-merge commits was removed"; fi
assert_audit_has "11k: audit records the tip mismatch" "prune=tip-differs-kept"

# 11k2. POSITIVE CONTROL (HIMMEL-2227): a worktree held open by a live native
# process is detected BEFORE the remove and skipped WHOLE. This is the case
# that FAILS before the fix (the old code let git's non-atomic-on-Windows
# remove gut the tree, then called it "left in place") and PASSES after it.
# Windows-gated: a native pwsh process holding a directory is the only thing
# MEASURED to block the final rmdir — an MSYS bash holder does not (see the
# HIMMEL-2227 repro table cited in prune_merged_worktree's own comment) — so
# the failure mode is not constructible on other platforms.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        PWSH=$(command -v pwsh || command -v powershell || true)
        if [ -z "$PWSH" ]; then
            echo "  SKIP: no pwsh/powershell on PATH — HIMMEL-2227 in-use-worktree case needs a native Windows holder"
        else
            read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
            # Ready marker lives OUTSIDE the worktree (a sibling path), not
            # inside it: an extra untracked file INSIDE the tree perturbs the
            # very git-worktree-remove behaviour under test. Matches the
            # HIMMEL-2227 repro exactly. cygpath -m (not a bare argv pass) so
            # a native pwsh.exe gets the real Windows path, not MSYS's naive
            # /tmp -> C:\tmp argv mangling (which is a DIFFERENT, wrong root
            # from /tmp's actual mount).
            ready="$P_WT.mog-test-ready"
            ready_win=$(cygpath -m "$ready" 2>/dev/null || printf '%s' "$ready")
            rm -f "$ready"
            ( cd "$P_WT" && "$PWSH" -NoProfile -Command "New-Item -ItemType File '$ready_win' | Out-Null; Start-Sleep 30" ) &
            HOLDER=$!
            tries=0
            while [ ! -f "$ready" ] && [ "$tries" -lt 100 ]; do
                sleep 0.1
                tries=$((tries + 1))
            done
            if [ ! -f "$ready" ]; then
                fail "11k2: the pwsh holder never signaled ready — cannot exercise the in-use case"
            else
                MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                    run_mog 0 "merged + in-use worktree -> skipped, exit 0"
                if [ -d "$P_WT" ]; then pass; else fail "11k2: in-use worktree directory is gone"; fi
                if [ -e "$P_WT/.git" ]; then pass; else fail "11k2: in-use worktree's .git is gone (gutted)"; fi
                if [ -f "$P_WT/work.txt" ] && grep -qF "feat/mog-prune" "$P_WT/work.txt"; then
                    pass
                else
                    fail "11k2: in-use worktree's work.txt did not survive (the pre-fix HIMMEL-2227 wreck)"
                fi
                if wt_list_has "$P_REPO" "$P_WT"; then
                    pass
                else
                    fail "11k2: in-use worktree's 'git worktree list' row is gone"
                fi
                if prune_branch_gone "$P_REPO"; then fail "11k2: branch deleted despite an in-use worktree"; else pass; fi
                assert_audit_has "11k2: audit records the in-use skip" "prune=in-use-skipped"
                if [ -e "$P_WT.worktree-inuse-probe" ]; then
                    fail "11k2: a stranded .worktree-inuse-probe directory was left behind"
                else
                    pass
                fi
            fi
            # ALWAYS kill the holder, pass or fail, or the suite leaves an
            # orphan pwsh process behind.
            kill "$HOLDER" 2>/dev/null
            wait "$HOLDER" 2>/dev/null
        fi
        ;;
    *)
        echo "  SKIP: not Windows — a live process's cwd blocks neither rename nor rmdir on POSIX, so the in-use case is not constructible here (HIMMEL-2227)"
        ;;
esac

# --- 11k4..11k7. HIMMEL-2517 — a live shell-suite run inside the tree ------
# The HIMMEL-2227 probe above cannot see this case AT ALL on POSIX: a process's
# cwd blocks neither the rename nor the rmdir, so 11k2 is Windows-gated and the
# prune sails straight through — which is exactly what happened twice on
# 2026-09-05 (PRs #2133, #2134) and again at 04:50 on #2150. These four cases
# are the POSIX half of the same guarantee, and they are Linux-gated for the
# mirror-image reason: /proc/<pid>/cwd is the only cwd oracle the detector has.
#
# The holder is a REAL process, not a fake lock file: the detector reads the
# process table, so anything less would test nothing. Its script is named
# `run-shell-tests.sh` (that name in argv is half the predicate) and lives
# OUTSIDE the fixture worktree — an extra untracked file inside the tree would
# perturb the very `git worktree remove` behaviour under test, the same
# reasoning 11k2's ready-marker placement records.
#
# Four cases, because the predicate has two independent halves and both must be
# shown load-bearing rather than merely present:
#   11k4  runner cwd INSIDE the tree                     -> refused
#   11k5  runner cwd OUTSIDE, argv silent about the tree -> pruned  (control)
#   11k6  runner cwd OUTSIDE, argv NAMES the tree        -> refused (queued-runner shape)
#   11k7  non-runner process cwd INSIDE the tree         -> pruned  (control)
#   11k8  runner argv names a PREFIX-SHARING sibling     -> pruned  (control)
#   11k9  a non-runner process that NAMES a runner      -> pruned  (control)
#   11k10 argv names a path that merely ENDS with ours  -> pruned  (control)
#   11k11 ONE argument embedding a space and our path  -> pruned  (control)
#   11k12 relative argv path, runner cwd OUTSIDE tree  -> refused
#   11k13 relative argv path spelled through ./ and ../ -> refused
# 11k5 and 11k7 are the controls that keep 11k4/11k6 honest: without them a
# detector that simply always refused would pass just as well.
case "$(uname -s)" in
    Linux*)
        # A failed mktemp leaves this EMPTY, and every path below is built on
        # it — the holder scripts would be written to, and later deleted from,
        # the filesystem root, and 11k4-11k9 would go vacuously green because no
        # holder ever started (round-4 CR finding codex-2, the same class as
        # round 2's on the Case 21 sandboxes). Capture the failure here.
        SUITE_HOLDER_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mog-2517-holder.XXXXXX")
        if [ -z "$SUITE_HOLDER_DIR" ] || [ ! -d "$SUITE_HOLDER_DIR" ]; then
            fail "11k4-11k9: mktemp -d produced no holder sandbox — refusing to build fixture paths on an empty root"
            exit 1
        fi
        cat > "$SUITE_HOLDER_DIR/run-shell-tests.sh" <<'SHEOF'
#!/usr/bin/env bash
# $1 = ready marker. Touch it (proving this process reached execution — a
# holder that never ran would make every assertion below vacuous), then idle
# until the marker is removed. Self-bounded at ~60s so a failing case can never
# strand this process on the box.
touch "$1"
n=0
while [ -e "$1" ] && [ "$n" -lt 300 ]; do sleep 0.2; n=$((n + 1)); done
SHEOF
        cp "$SUITE_HOLDER_DIR/run-shell-tests.sh" "$SUITE_HOLDER_DIR/sleeper.sh"

        # start_suite_holder <cwd> <script> [extra-argv...] — sets HOLDER_PID
        # and HOLDER_READY. `bash -c '... exec ...'` rather than a subshell so
        # HOLDER_PID IS the holder itself: its argv is what the detector matches
        # and killing it kills the thing under test, not a parent of it.
        start_suite_holder() {
            local hcwd="$1" hscript="$2"; shift 2
            HOLDER_READY="$SUITE_HOLDER_DIR/ready.$$.$RANDOM"
            rm -f "$HOLDER_READY"
            bash -c 'cd "$1" || exit 1; s="$2"; shift 2; exec bash "$s" "$@"' \
                _ "$hcwd" "$hscript" "$HOLDER_READY" "$@" &
            HOLDER_PID=$!
            local tries=0
            while [ ! -f "$HOLDER_READY" ] && [ "$tries" -lt 100 ]; do
                sleep 0.1
                tries=$((tries + 1))
            done
            [ -f "$HOLDER_READY" ]
        }
        stop_suite_holder() {
            rm -f "$HOLDER_READY"
            kill "$HOLDER_PID" 2>/dev/null
            wait "$HOLDER_PID" 2>/dev/null
        }

        # 11k4. POSITIVE: a runner executing inside the merged worktree. This is
        # the case that FAILS before the fix (prune=removed, tree gone, and the
        # runner then renders the 422-red artifact) and PASSES after it.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        if ! start_suite_holder "$P_WT" "$SUITE_HOLDER_DIR/run-shell-tests.sh"; then
            fail "11k4: the suite holder never signaled ready — cannot exercise the live-run case"
        else
            pass  # holder reached execution: every assertion below is about a real process
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + live suite run inside the worktree -> kept, exit 0"
            assert_audit_has "11k4: audit records the live-run refusal" "prune=suite-running-kept"
            if [ -d "$P_WT" ]; then pass; else fail "11k4: worktree with a live suite run was removed"; fi
            if [ -e "$P_WT/.git" ]; then pass; else fail "11k4: worktree's .git is gone (gutted)"; fi
            if [ -f "$P_WT/work.txt" ]; then pass; else fail "11k4: worktree contents did not survive"; fi
            if wt_list_has "$P_REPO" "$P_WT"; then pass; else fail "11k4: worktree's 'git worktree list' row is gone"; fi
            if prune_branch_gone "$P_REPO"; then fail "11k4: branch deleted despite a kept worktree"; else pass; fi
            case "$LAST_ERR" in
                *"is running a shell-test suite"*"$HOLDER_PID"*) pass ;;
                *) fail "11k4: the refusal message does not name the holding pid $HOLDER_PID (got: ${LAST_ERR:-<none>})" ;;
            esac
        fi
        stop_suite_holder

        # 11k5. NEGATIVE CONTROL: same runner, same name in argv, but anchored
        # OUTSIDE the tree and saying nothing about it. A detector that keyed on
        # "a run-shell-tests.sh exists anywhere" would refuse here and strand
        # every merged worktree on the box for as long as any suite is running.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        if ! start_suite_holder "$SUITE_HOLDER_DIR" "$SUITE_HOLDER_DIR/run-shell-tests.sh"; then
            fail "11k5: the suite holder never signaled ready — control not established"
        else
            pass  # the control's own process really is live while the prune runs
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + unrelated suite run elsewhere -> pruned, exit 0"
            assert_audit_has "11k5: an unrelated run does not block the prune" "prune=removed branch=deleted"
            if [ -d "$P_WT" ]; then fail "11k5: worktree survived despite no run inside it"; else pass; fi
        fi
        stop_suite_holder

        # 11k6. POSITIVE, the QUEUED-runner shape: a runner still waiting out
        # SUITE_LOCK_WAIT owns no lock and has executed nothing, so the lock's
        # owner file does not know about it — but it names the worktree it will
        # run against. That is the 04:50 #2150 instance; the lock file alone
        # would have missed it.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        # Normalised, because the argv match is a literal substring test against
        # the path merge-on-green itself resolved (cd + pwd) — a symlinked
        # TMPDIR would otherwise make the two spellings differ and the case
        # would pass or fail for the wrong reason.
        P_WT=$(cd "$P_WT" && pwd)
        if ! start_suite_holder "$SUITE_HOLDER_DIR" "$SUITE_HOLDER_DIR/run-shell-tests.sh" "$P_WT/scripts"; then
            fail "11k6: the suite holder never signaled ready — cannot exercise the argv-match case"
        else
            pass
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + a run whose argv names the worktree -> kept, exit 0"
            assert_audit_has "11k6: audit records the argv-match refusal" "prune=suite-running-kept"
            if [ -d "$P_WT" ]; then pass; else fail "11k6: worktree named by a live runner's argv was removed"; fi
        fi
        stop_suite_holder

        # 11k7. NEGATIVE CONTROL: a process cwd'd inside the tree that is NOT a
        # suite runner (identical script, different name). The refusal must key
        # on the runner, not on "anything is in there" — merge-on-green's own
        # armed chain legs sit in these trees, and blocking on them would undo
        # HIMMEL-1970's whole point.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        if ! start_suite_holder "$P_WT" "$SUITE_HOLDER_DIR/sleeper.sh"; then
            fail "11k7: the sleeper never signaled ready — control not established"
        else
            pass
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + a non-runner process inside the worktree -> pruned, exit 0"
            assert_audit_has "11k7: a non-runner process does not block the prune" "prune=removed branch=deleted"
            if [ -d "$P_WT" ]; then fail "11k7: worktree survived a prune it should have allowed"; else pass; fi
        fi
        stop_suite_holder

        # 11k8. NEGATIVE CONTROL (round-2 CR finding codex-5): a runner whose
        # argv names a SIBLING worktree that merely shares this one's path as a
        # prefix. `.claude/worktrees/` names are branch-derived, so
        # `fix+himmel-2517-prune-race` and `fix+himmel-2517-prune-race-2` coexist
        # routinely — an open substring match would pin every merged tree open
        # for as long as any longer-named sibling is under test.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        P_WT=$(cd "$P_WT" && pwd)
        if ! start_suite_holder "$SUITE_HOLDER_DIR" "$SUITE_HOLDER_DIR/run-shell-tests.sh" "${P_WT}-sibling/scripts"; then
            fail "11k8: the suite holder never signaled ready — control not established"
        else
            pass
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + a run naming a PREFIX-SHARING sibling -> pruned, exit 0"
            assert_audit_has "11k8: a prefix-sharing sibling does not block the prune" "prune=removed branch=deleted"
            if [ -d "$P_WT" ]; then fail "11k8: worktree retained for a run that named only a sibling path"; else pass; fi
        fi
        stop_suite_holder

        # 11k10. NEGATIVE CONTROL (round-5 CR finding codex-2): the argv match
        # needs a LEADING boundary as well as a trailing one. 11k8 covers a path
        # that merely starts with ours; this covers one that merely ENDS with it
        # — a backup or snapshot root such as `/backup<worktree>/scripts`, which
        # an open-prefix pattern would read as the worktree itself.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        P_WT=$(cd "$P_WT" && pwd)
        if ! start_suite_holder "$SUITE_HOLDER_DIR" "$SUITE_HOLDER_DIR/run-shell-tests.sh" "/backup${P_WT}/scripts"; then
            fail "11k10: the suite holder never signaled ready — control not established"
        else
            pass
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + a run naming a path that merely ENDS with ours -> pruned, exit 0"
            assert_audit_has "11k10: a path ending with ours does not block the prune" "prune=removed branch=deleted"
            if [ -d "$P_WT" ]; then fail "11k10: worktree retained for a run that named only a superstring path"; else pass; fi
        fi
        stop_suite_holder

        # 11k11. NEGATIVE CONTROL (round-6 CR finding codex-2): ONE argument that
        # happens to contain a space and our worktree path. Flattened to a
        # string, that is indistinguishable from two arguments and matches every
        # boundary rule rounds 2 and 5 added; read on the kernel's own NUL
        # delimiters it is a single argument that is neither the path nor rooted
        # at it. This is the case the argv rewrite exists for, and the only one of
        # the six live-run controls that the pre-rewrite pattern could not pass.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        P_WT=$(cd "$P_WT" && pwd)
        if ! start_suite_holder "$SUITE_HOLDER_DIR" "$SUITE_HOLDER_DIR/run-shell-tests.sh" "unrelated $P_WT"; then
            fail "11k11: the suite holder never signaled ready — control not established"
        else
            pass
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + a run whose ONE argument merely embeds our path -> pruned, exit 0"
            assert_audit_has "11k11: an embedded-space argument is not an argv element equal to our path" "prune=removed branch=deleted"
            if [ -d "$P_WT" ]; then fail "11k11: worktree retained for a single argument that merely embeds its path"; else pass; fi
        fi
        stop_suite_holder

        # 11k12. POSITIVE (round-8 CR finding codex-2): a runner launched from
        # OUTSIDE the tree that names it RELATIVELY. Its cwd is the parent, so
        # the cwd check cannot see it, and `wt/scripts` is not the absolute path,
        # so a literal argv comparison cannot either — yet the scan root it walks
        # IS inside the worktree, and pruning deletes it mid-run. A false
        # negative, which is the one direction this detector may not have.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        P_WT=$(cd "$P_WT" && pwd)
        P_PARENT=$(cd "$P_WT/.." && pwd)
        P_BASE=${P_WT##*/}
        if ! start_suite_holder "$P_PARENT" "$SUITE_HOLDER_DIR/run-shell-tests.sh" "$P_BASE/scripts"; then
            fail "11k12: the suite holder never signaled ready — cannot exercise the relative-argv case"
        else
            pass
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + a run naming the tree RELATIVELY from outside it -> kept, exit 0"
            assert_audit_has "11k12: a relative argv path resolves against the runner's cwd" "prune=suite-running-kept"
            if [ -d "$P_WT" ]; then pass; else fail "11k12: worktree removed under a runner that named it relatively"; fi
            if [ -f "$P_WT/work.txt" ]; then pass; else fail "11k12: worktree contents did not survive"; fi
        fi
        stop_suite_holder

        # 11k13. POSITIVE (round-9 CR finding codex-2): a relative argument that
        # reaches the tree through `..`. Prefixing the cwd is not enough — the
        # resulting string names the worktree without SPELLING it — so the
        # comparison has to canonicalize. Same direction as 11k12: a miss here is
        # a false negative and the worktree is deleted under a live run.
        #
        # The `..` must come BEFORE the worktree path, not after it. A first
        # draft used `<wt>/../<wt>/scripts` from the parent and did NOT
        # discriminate: `case` globs match `/`, so `$path/*` happily matches
        # `<wt>/../<wt>/scripts` and the uncanonicalized mutant passed too.
        # Launching from the sibling repo directory and reaching back out is what
        # produces a string the prefix form genuinely cannot match.
        read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
        P_WT=$(cd "$P_WT" && pwd)
        P_BASE=${P_WT##*/}
        if ! start_suite_holder "$P_REPO" "$SUITE_HOLDER_DIR/run-shell-tests.sh" "../$P_BASE/scripts"; then
            fail "11k13: the suite holder never signaled ready — cannot exercise the dotted-path case"
        else
            pass
            MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                run_mog 0 "merged + a run reaching the tree through ../ -> kept, exit 0"
            assert_audit_has "11k13: a dotted relative path is canonicalized before comparing" "prune=suite-running-kept"
            if [ -d "$P_WT" ]; then pass; else fail "11k13: worktree removed under a runner that named it through ../"; fi
            if [ -f "$P_WT/work.txt" ]; then pass; else fail "11k13: worktree contents did not survive"; fi
        fi
        stop_suite_holder

        # 11k9. NEGATIVE CONTROL (round-4 CR finding codex-3): a process that
        # NAMES a runner without being one — an editor or a `tail -f` opened on
        # `run-shell-tests.sh` — with its cwd inside the merged worktree. Naming
        # is not running, and someone editing that file in that worktree is
        # precisely who would otherwise pin their own merged tree open.
        #
        # The holder must be a REAL binary, not another bash script: a script
        # with a shebang is exec'd through its interpreter, so the kernel rewrites
        # argv[0] to `bash` and the case would pass for the wrong reason. A copy
        # of `tail` named `vim` gives a genuine non-shell argv[0] while its
        # argument carries the runner token the detector matches on.
        TAIL_BIN=$(command -v tail 2>/dev/null || true)
        if [ -z "$TAIL_BIN" ]; then
            echo "  SKIP: no tail on PATH — 11k9 needs a real non-shell binary as its holder"
        else
            read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
            cp "$TAIL_BIN" "$SUITE_HOLDER_DIR/vim"
            chmod +x "$SUITE_HOLDER_DIR/vim"
            HOLDER_READY="$SUITE_HOLDER_DIR/unused-11k9"
            bash -c 'cd "$1" || exit 1; shift; exec "$@"' _ "$P_WT" \
                "$SUITE_HOLDER_DIR/vim" -f "$SUITE_HOLDER_DIR/run-shell-tests.sh" &
            HOLDER_PID=$!
            # Readiness is read from the process table itself rather than from a
            # marker file: it is the exact state the detector inspects, so a pass
            # here cannot mean "the holder had not started yet".
            tries=0
            holder_cwd=""
            holder_cmd=""
            while [ "$tries" -lt 100 ]; do
                holder_cmd=$(tr '\0' ' ' < "/proc/$HOLDER_PID/cmdline" 2>/dev/null || printf '')
                holder_cwd=$(readlink -f "/proc/$HOLDER_PID/cwd" 2>/dev/null || printf '')
                case "$holder_cmd" in
                    *run-shell-tests.sh*) [ -n "$holder_cwd" ] && break ;;
                esac
                sleep 0.1
                tries=$((tries + 1))
            done
            case "$holder_cmd" in
                *run-shell-tests.sh*) holder_named=1 ;;
                *) holder_named=0 ;;
            esac
            if [ "$holder_named" -ne 1 ] || [ "$holder_cwd" != "$(cd "$P_WT" && pwd)" ]; then
                fail "11k9: the editor-shaped holder never reached the state under test (cmd='$holder_cmd' cwd='$holder_cwd')"
            else
                # Both halves of the trap are demonstrably in place: the runner
                # token IS in this process's argv, and its cwd IS the worktree.
                # Only argv[0] differs from a real runner.
                pass
                MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
                    run_mog 0 "merged + a non-runner process NAMING a runner -> pruned, exit 0"
                assert_audit_has "11k9: naming a runner is not running one" "prune=removed branch=deleted"
                if [ -d "$P_WT" ]; then fail "11k9: worktree retained for an editor that merely names the runner"; else pass; fi
            fi
            stop_suite_holder
        fi

        rm -rf "$SUITE_HOLDER_DIR"
        ;;
    *)
        echo "  SKIP: not Linux — the live-suite-run detector reads /proc/<pid>/cwd, which exists nowhere else (HIMMEL-2517)"
        ;;
esac

# 11k3. A remove that fails PART-WAY (git-for-Windows deletes contents +
# deregisters the admin entry, then fails the final rmdir) is reported as
# `gutted`, never as "left in place". The gutted shape is only reachable
# through a real race otherwise (11k2 above), so this drives it deterministically
# via a `git` shim on PATH for this one run: it passes every argument through
# to the REAL git EXCEPT the exact `worktree remove <fixture-worktree>`
# invocation, where it reproduces the MEASURED git-for-Windows wreck rather
# than invented behaviour — see the HIMMEL-2227 repro table in
# prune_merged_worktree's comment. A test-only seam in production code is not
# acceptable here; a PATH shim is.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
REAL_GIT=$(command -v git)
P_REPO_NORM=$(cd "$P_REPO" && pwd)
P_WT_NORM=$(cd "$P_WT" && pwd)
shimdir=$(mktemp -d "${TMPDIR:-/tmp}/mog-gitshim.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
cat > "$shimdir/git" <<GITSHIM
#!/usr/bin/env bash
REAL_GIT="$REAL_GIT"
P_REPO_NORM="$P_REPO_NORM"
P_WT_NORM="$P_WT_NORM"
if [ "\$1" = "-C" ] && [ "\$3" = "worktree" ] && [ "\$4" = "remove" ]; then
    c2=\$(cd "\$2" 2>/dev/null && pwd) || c2="\$2"
    c5=\$(cd "\$5" 2>/dev/null && pwd) || c5="\$5"
    if [ "\$c2" = "\$P_REPO_NORM" ] && [ "\$c5" = "\$P_WT_NORM" ]; then
        # Reproduce the MEASURED HIMMEL-2227 wreck: contents + .git gone,
        # admin row pruned away, empty directory left, non-zero exit.
        rm -rf "\$P_WT_NORM"
        "\$REAL_GIT" -C "\$P_REPO_NORM" worktree prune >/dev/null 2>&1
        mkdir -p "\$P_WT_NORM"
        exit 1
    fi
fi
exec "\$REAL_GIT" "\$@"
GITSHIM
chmod +x "$shimdir/git"
PATH="$shimdir:$PATH" MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "merged but remove fails partway -> reported gutted, exit 0"
assert_audit_has "11k3: audit records the gutted outcome" "prune=gutted"
assert_err_has "11k3: operator message says FAILED PARTWAY" "FAILED PARTWAY"
assert_err_has "11k3: operator message says GUTTED" "GUTTED"
if prune_branch_gone "$P_REPO"; then fail "11k3: branch deleted despite a gutted (unverified) tree"; else pass; fi

# --- 11L..11o. HIMMEL-1346 CR-marker clear on the merge path ----------------
# A merge used to leave the branch's cr-pending marker behind; the marker lives
# in the SHARED git-common-dir while the pr-create guard resolves the branch
# from the session cwd, so it then blocked `gh pr create` on UNRELATED branches.
# The merge path must clear it THROUGH clear-cr-marker.sh (never a raw rm, which
# is the self-declare-clean pattern HIMMEL-1064 exists to stop) and record the
# outcome on the MERGED audit line. Same prune fixture — a real throwaway repo.
mk_marker() {
    mkdir -p "$1/.git/cr-pending/$(dirname "$2")"
    printf '2026-08-20T00:00:00Z | deadbeef | full | origin | refs/heads/%s | https://example.invalid/r.git | cafebabe\n' \
        "$2" > "$1/.git/cr-pending/$2"
}

# 11L. Marker present + confirmed merge → cleared through the chokepoint, with
# the branch it certifies, and the MERGED line carries marker=cleared.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
mk_marker "$P_REPO" "feat/mog-prune"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "marker present → cleared via clear-cr-marker.sh, exit 0"
assert_clear_has "11L: the chokepoint was invoked for the merged branch" "feat/mog-prune"
assert_audit_has "11L: audit records the marker outcome" "marker=cleared"
# The clear must run BEFORE the merge, the one thing that keeps this feature
# from silently rotting: afterwards deleteBranchOnMerge has removed the remote
# head branch and the chokepoint refuses (16) for EVERY merged branch, so a
# post-merge clear would pass its tests while never clearing anything in
# production. Ordered via the gh log, which the stub clearer also writes to.
clear_ln=$(grep -n '^clear-cr-marker ' "$LAST_GH_LOG" | head -1 | cut -d: -f1)
merge_ln=$(grep -n '^pr merge ' "$LAST_GH_LOG" | head -1 | cut -d: -f1)
if [ -n "$clear_ln" ] && [ -n "$merge_ln" ] && [ "$clear_ln" -lt "$merge_ln" ]; then
    pass
else
    fail "11L: the marker clear must precede the merge (clear@${clear_ln:-none} merge@${merge_ln:-none})"
fi

# 11m. The chokepoint REFUSES (14 = no responders at that sha) → the merge
# verdict and exit are unchanged (it already landed), and the failure is
# RECORDED rather than swallowed.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
mk_marker "$P_REPO" "feat/mog-prune"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" STUB_CLEAR_RC=14 \
    run_mog 0 "marker clear refused → merge still exit 0"
assert_audit_has "11m: audit records the clear failure" "marker=clear-rc=14"
assert_audit_has "11m: the merge is still recorded as MERGED" "MERGED repo="

# 11n. No marker → the chokepoint is not invoked at all (its gates include a
# second check-ci watch, paid for nothing), and the line says so.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "no marker → nothing to clear, exit 0"
assert_clear_not_invoked "11n: no marker means no chokepoint call"
assert_audit_has "11n: audit records the absent marker" "marker=absent"

# 11o. --dry-run changes nothing: clearing is a real mutation, so the marker
# must survive a dry run untouched.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
mk_marker "$P_REPO" "feat/mog-prune"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
    run_mog 0 "dry-run does not clear the marker" -- --dry-run
assert_clear_not_invoked "11o: dry-run leaves the chokepoint uninvoked"
if [ -f "$P_REPO/.git/cr-pending/feat/mog-prune" ]; then pass; else fail "11o: dry-run removed the marker file"; fi

# --- 11p..11q. HIMMEL-2383 after-report pending marker -----------------------
# Red-first: no SUMMARY comment on the PR yet at merge time -> a local marker
# file is written (same dir shape as cr-pending) and the audit line says so.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" STUB_NUM=77 \
    run_mog 0 "11p: no after-report SUMMARY yet -> pending marker written"
if [ -f "$P_REPO/.git/after-report-pending/feat/mog-prune" ]; then
    pass
else
    fail "11p: after-report-pending marker file was not written"
fi
assert_audit_has "11p: audit records the pending after-report" "after-report=pending"

# 11q. A SUMMARY comment already exists at merge time (STUB_AFTER_REPORT_SUMMARIES=1)
# -> no marker written (and a stale one from a prior run is cleared), audit
# says 'posted'.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
mkdir -p "$P_REPO/.git/after-report-pending/feat"
printf 'stale\n' > "$P_REPO/.git/after-report-pending/feat/mog-prune"
MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" STUB_NUM=77 \
    STUB_AFTER_REPORT_SUMMARIES=1 run_mog 0 "11q: after-report already posted -> no pending marker"
if [ -f "$P_REPO/.git/after-report-pending/feat/mog-prune" ]; then
    fail "11q: a stale after-report-pending marker was not cleared"
else
    pass
fi
assert_audit_has "11q: audit records the posted after-report" "after-report=posted"

# 12. A truthy-but-not-1 opt-in also enables (yes/on/true).
ARMAUTOMERGE=yes run_mog 0 "ARMAUTOMERGE=yes also enables"

# 13. `--help` prints the WHOLE header reference, not a truncated prefix
# (coderabbit, public round). The old `sed -n '2,30p'` stopped at exit code 11,
# so an operator diagnosing a 12-16 refusal saw none of those codes. The range
# is now anchored to the `set -uo pipefail` line, so a header edit cannot
# silently truncate the reference again — this test is what holds that.
# --help is parsed before every gate, so it needs no stubs.
help_out=$(bash "$MOG" --help 2>&1)
help_rc=$?
if [ "$help_rc" -eq 0 ]; then
    pass
else
    fail "--help exits 0 (got $help_rc)"
fi
for _code in 0 10 11 12 13 14 15 16; do
    if grepq "$help_out" -E "^ *${_code} +[a-z]"; then
        pass
    else
        fail "--help documents exit code ${_code}"
    fi
done
for _doc in MERGE_ON_GREEN_LOG ARMAUTOMERGE 'GATE INTEGRITY'; do
    if grepq "$help_out" "$_doc"; then
        pass
    else
        fail "--help includes $_doc"
    fi
done
# The terminating `set -uo pipefail` line is code, not help text — it must be
# dropped, or the range anchor leaks the first line of the script body.
if grepq "$help_out" 'set -uo pipefail'; then
    fail "--help leaks the 'set -uo pipefail' code line"
else
    pass
fi

# HIMMEL-1495 hermeticity guard — prove the startup scrub holds. Re-run this
# suite in a subprocess EXPORTING the exact armed bypass env an
# --automerge-armed shell carries; the reinvoked copy's startup unset must
# neutralize it, so its probe (no-opt-in still refuses) passes and it exits 0.
# Remove the startup `unset ARMAUTOMERGE CR_MERGE_GATE_OK` and the reinvoked
# copy instead reads ARMAUTOMERGE=1 as opted-in and exits non-zero.
# Recursion-safe: the sentinel suppresses the guard in the reinvoked copy.
if [ "${HIMMEL_1495_SELF:-0}" != "1" ]; then
    _armed_log="$(mktemp)"
    if CR_MERGE_GATE_OK=1 ARMAUTOMERGE=1 HIMMEL_1495_SELF=1 bash "$SCRIPT_DIR/test-merge-on-green.sh" >"$_armed_log" 2>&1; then
        pass; echo "  hermetic-to-armed-env (self-reinvoke exits 0)"
    else
        fail "hermetic-to-armed-env (startup scrub missing?)"; sed 's/^/  armed: /' "$_armed_log" >&2
    fi
    rm -f "$_armed_log"
fi


# ── HIMMEL-2380: the merge record names its reviewer coverage ────────────────
# check-ci.sh writes to THIS script's stdout, so an operator watching a live run
# already sees what it says about CodeRabbit. An ARMAUTOMERGE chain has no such
# operator: the audit log is the only account of the merge that survives it, and
# `gate=check-ci:0` alone cannot tell "CodeRabbit reviewed this and passed" from
# "there is no CodeRabbit here". The cr= field is that distinction, and it is
# recorded on every state — a field that shows up only on bad news is one nobody
# learns to look for.
#
# The default cwd is a throwaway non-repo, so the state is `not-configured`
# without any pinning. MOG_CR_APP is the seam for the other states, mirroring
# test-check-ci.sh's CR_APP_OVERRIDE and pinned for the same reason: an
# unpinned probe would read whichever clone the suite happens to run from.

# 2380-1 — the adopter's merge is recorded AS the adopter's merge.
run_mog 0 "2380-1: adopter merge records cr=not-configured"
assert_audit_has "2380-1: MERGED line carries the CR state" "gate=check-ci:0"
assert_audit_has "2380-1: and names it as not-configured" "cr=not-configured"

# 2380-2 — and it VARIES. Without this the field could be a hardcoded string
# and 2380-1 would never notice.
MOG_CR_APP=1 run_mog 0 "2380-2: an armed repo records cr=armed"
assert_audit_has "2380-2: MERGED line says armed" "cr=armed"

# 2380-3 — the pre-existing fields are byte-stable. The cr= field was APPENDED,
# never interleaved: every assertion any other case makes about this line reads
# the same bytes it always did.
MOG_CR_APP=0 run_mog 0 "2380-3: a disabled repo records cr=disabled"
assert_audit_has "2380-3: disabled state recorded" "cr=disabled"
assert_audit_has "2380-3: the merge fields ahead of it are unchanged" "prune="

# 2380-4 — --dry-run records it too. A dry run is the shape an operator uses to
# ask "what would this merge do", and the answer includes who reviewed it.
run_mog 0 "2380-4: dry-run records the CR state" -- --dry-run
assert_audit_has "2380-4: DRYRUN line carries cr=" "DRYRUN"
assert_audit_has "2380-4: with the state named" "cr=not-configured"

# 2380-5 — the `broken` state, end to end. Raised by the codex critic on this
# PR's round 2, and it was right: cases 2380-1..4 cover not-configured / armed /
# disabled and omit the ONE state that motivated the whole field. `broken` is
# the only one where the pre-2380 behaviour was a genuinely false certification
# — the marker IS set, so the repo meant to have the CodeRabbit gates, and a
# value git cannot parse as a boolean silently disarms them. Recording every
# other state while leaving that one unverified would have shipped the field
# without its reason.
#
# Needs a REAL repo, because `broken` is the one state no env seam can stub:
# CR_APP short-circuits before the git config is read at all, so reaching it
# means an actual `git config --local himmel.coderabbit <unparseable>`. Reuses
# mk_prune_fixture (a throwaway repo + worktree) and MOG_CWD, the same way the
# 11-series marker cases do, with MOG_CR_APP left EMPTY so the marker path runs.
read -r P_REPO P_WT P_SHA <<< "$(mk_prune_fixture)"
git -C "$P_REPO" config --local himmel.coderabbit ture
# Prove the fixture is actually broken before the case trusts it (HIMMEL-2320 —
# a zero is not evidence without a positive control). If a future git parsed
# `ture`, this case would pass for the wrong reason: it would be asserting
# cr=broken on a repo that is merely unarmed, i.e. testing nothing.
if git -C "$P_REPO" config --bool --local --get himmel.coderabbit >/dev/null 2>&1; then
    fail "2380-5 setup: fixture is not broken — this git parses 'ture' as a boolean"
else
    MOG_CR_APP="" MOG_CWD="$P_REPO" STUB_SHA="$P_SHA" STUB_HEAD_BRANCH="feat/mog-prune" \
        run_mog 0 "2380-5: an unparseable himmel.coderabbit marker records cr=broken"
    assert_audit_has "2380-5: the merge record names the broken config" "cr=broken"
    # And it MERGED anyway. This is the half that would be easy to get wrong in
    # the other direction: `broken` warns, it never blocks (HIMMEL-1125 exists
    # to stop blocking on CodeRabbit's absence, and a config typo must not wedge
    # a merge). A future change that made `broken` fail closed fails HERE.
    assert_audit_has "2380-5: a broken marker warns but does not block the merge" "MERGED repo="
fi
echo
echo "merge-on-green: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
