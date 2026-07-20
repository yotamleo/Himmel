#!/usr/bin/env bash
# Tests for merge-public-on-green.sh — the HIMMEL-1213 Telegram-authorized PUBLIC
# merge chokepoint. Mirrors scripts/handover/test-merge-on-green.sh's pattern: the
# wrapper has NO env seams for `gh`/`check-ci` (gate integrity), so each case runs
# a COPY of the script tree ($tmp/scripts/merge-public-on-green.sh) with a stub
# check-ci.sh at the fixed sibling path ($tmp/scripts/check-ci.sh) and a stub `gh`
# FIRST on PATH. Asserts the fail-closed gate sequence + that a real merge only
# ever fires with --squash --admin --match-head-commit <certified-sha>, scoped to
# the pinned repo via --repo throughout (never cwd-derived).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MPOG="$SCRIPT_DIR/merge-public-on-green.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# run_mpog <expected-exit> <test-name> [<pr>] [-- extra args...]
# Stub behavior controlled by env vars exported before the call:
#   STUB_NWO             the PR's owner/repo (in its url). Default = TEST_REPO.
#   STUB_NUM             PR number the stub echoes back. Default 77.
#   STUB_STATE           initial PR state. Default OPEN.
#   STUB_STATE_FAIL=1    the meta `gh pr view` exits 1 (API failure).
#   STUB_NO_PR=1         the meta `gh pr view` exits 1 with "no pull requests found".
#   STUB_SHA             `headRefOid` at the initial meta query. Default fixed sha.
#   STUB_BASE            `baseRefName` at the initial meta query. Default main.
#   STUB_DEFAULT_BRANCH  `defaultBranchRef.name` (repo view). Default main.
#   STUB_STATE_PREMERGE  fresh `state` at the gate-4b re-verify. Default = STUB_STATE.
#   STUB_BASE_PREMERGE   fresh `baseRefName` at gate 4b. Default = STUB_BASE.
#   STUB_SHA_PREMERGE    fresh `headRefOid` at gate 4b. Default = STUB_SHA.
#   STUB_CI_RC           exit code of the stub check-ci.sh. Default 0.
#   NO_CHECK_CI=1        omit the stub check-ci.sh (sibling path absent).
#   STUB_MERGE_FAIL=1    `gh pr merge` exits 1 (generic failure).
#   STUB_POST_STATE      PR state the post-merge re-query returns. Default MERGED.
#   STUB_AUDIT_UNWRITABLE=1  point the audit sink at an unwritable path.
#   CLAUDECODE_SET=1     leave CLAUDECODE SET for this run (defense-in-depth test;
#                        every OTHER case explicitly unsets it, since this test
#                        suite itself runs inside a Claude Code session).
#   CLI_SHA              the operator-approved SHA passed as the script's OWN 2nd
#                        positional arg. Defaults to STUB_SHA (so by default the
#                        "approved" value equals the mocked "actual head" value);
#                        set DIFFERENT from STUB_SHA to exercise the head-identity
#                        gate specifically (a case that must NOT also break the
#                        "empty head SHA" test, which needs a valid CLI arg but an
#                        empty mocked API response).
# After the run: $LAST_GH_LOG, $LAST_AUDIT, $LAST_CHECKCI_LOG.
TEST_REPO="acme/pub"
LAST_GH_LOG=""; LAST_AUDIT=""; LAST_CHECKCI_LOG=""
run_mpog() {
    local expected="$1" name="$2" pr="${3:-77}"; shift 3 || shift 2
    [ "${1:-}" = "--" ] && shift
    local tmp; tmp=$(mktemp -d)
    local ghlog="$tmp/gh.log"; : > "$ghlog"
    local ccilog="$tmp/checkci.log"; : > "$ccilog"
    local audit="$tmp/audit.log"
    [ "${STUB_AUDIT_UNWRITABLE:-0}" = "1" ] && audit="$tmp/nodir/audit.log"  # parent absent → unwritable

    # Copy the script into a temp tree so its fixed sibling `check-ci.sh` resolves
    # to our stub — no CHECK_CI env override exists.
    mkdir -p "$tmp/scripts" "$tmp/bin"
    cp "$MPOG" "$tmp/scripts/merge-public-on-green.sh"
    if [ "${NO_CHECK_CI:-0}" != "1" ]; then
        cat > "$tmp/scripts/check-ci.sh" <<STUBCI
#!/usr/bin/env bash
echo "\$*" >> "$ccilog"
# The chokepoint calls check-ci TWICE: gate 4 (full, no flag) then gate 4c
# (\`--threads-only\`, the fresh pre-merge review re-check). STUB_THREADS_RC lets a
# test pass gate 4 (STUB_CI_RC) but fail the fresh review gate (review-race).
case "\$*" in
    *--threads-only*) exit ${STUB_THREADS_RC:-0} ;;
    *) exit ${STUB_CI_RC:-0} ;;
esac
STUBCI
        chmod +x "$tmp/scripts/check-ci.sh"
    fi

    # Stub gh, FIRST on PATH. FAILS CLOSED on an unrecognized query — an
    # unsupported verb/shape must not rubber-stamp a silent success.
    cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
verb="$1 $2"
json=""; jqexpr=""; repo_arg=""
shift 2 2>/dev/null || true
while [ $# -gt 0 ]; do
    case "$1" in
        --json) json="${2:-}"; shift 2 ;;
        --jq) jqexpr="${2:-}"; shift 2 ;;
        --repo) repo_arg="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
nwo="${STUB_NWO:-acme/pub}"
case "$verb" in
    "pr view")
        [ "${STUB_NO_PR:-0}" = "1" ] && { echo 'no pull requests found for branch "x"' >&2; exit 1; }
        [ "${STUB_STATE_FAIL:-0}" = "1" ] && { echo "gh: api error" >&2; exit 1; }
        case "$json" in
            "state,url,number,headRefOid,baseRefName")
                # 6 %s: state, nwo+num embedded in the url (2 of the 6), num AGAIN
                # as its own standalone field, sha, base — 5 pipe-separated fields.
                printf '%s|https://github.com/%s/pull/%s|%s|%s|%s' \
                    "${STUB_STATE-OPEN}" "$nwo" "${STUB_NUM:-77}" "${STUB_NUM:-77}" "${STUB_SHA-abc123def456}" "${STUB_BASE-main}" ;;
            "state,baseRefName,headRefOid")
                printf '%s|%s|%s' \
                    "${STUB_STATE_PREMERGE:-${STUB_STATE-OPEN}}" \
                    "${STUB_BASE_PREMERGE:-${STUB_BASE-main}}" \
                    "${STUB_SHA_PREMERGE:-${STUB_SHA-abc123def456}}" ;;
            "state")
                printf '%s' "${STUB_POST_STATE:-MERGED}" ;;
            *) echo "gh stub: unhandled 'pr view' query: --json '$json'" >&2; exit 90 ;;
        esac ;;
    "repo view")
        case "$json" in
            defaultBranchRef) printf '%s' "${STUB_DEFAULT_BRANCH-main}" ;;
            *) echo "gh stub: unhandled 'repo view' query: --json '$json'" >&2; exit 90 ;;
        esac ;;
    "pr merge")
        [ "${STUB_MERGE_FAIL:-0}" = "1" ] && { echo "merge conflict / head moved" >&2; exit 1; }
        echo "merged" ;;
    *) echo "gh stub: unsupported command: $*" >&2; exit 90 ;;
esac
exit 0
STUB
    chmod +x "$tmp/bin/gh"

    # Set CLAUDECODE deterministically — do NOT rely on the ambient environment
    # (codex CR-3): CLAUDECODE_SET=1 EXPLICITLY sets it so the gate-0 test fires in
    # CI envs that lack an ambient CLAUDECODE; otherwise clear it so the happy-path
    # gates run. Either way the value is pinned here, never inherited.
    local err rc claudecode_env
    if [ "${CLAUDECODE_SET:-0}" = "1" ]; then claudecode_env="CLAUDECODE=1"; else claudecode_env="CLAUDECODE="; fi
    if [ "${STUB_AUDIT_NOSINK:-0}" = "1" ]; then
        # No MERGE_PUBLIC_ON_GREEN_LOG override AND run from a NON-repo cwd so
        # _audit_sink's `git rev-parse --git-dir` fallback also fails → empty sink
        # → preflight must refuse (codex CR-3). ($tmp is a mktemp dir under the
        # system temp root, which has no .git ancestor.)
        mkdir -p "$tmp/norepo"
        ( cd "$tmp/norepo" && env $claudecode_env GH_LOG="$ghlog" CHECKCI_LOG="$ccilog" \
            CR_PUBLIC_REPO="$TEST_REPO" PATH="$tmp/bin:$PATH" \
            bash "$tmp/scripts/merge-public-on-green.sh" "$pr" "${CLI_SHA:-${STUB_SHA-abc123def456}}" "$@" ) >/dev/null 2>"$tmp/err"
    else
        env $claudecode_env GH_LOG="$ghlog" CHECKCI_LOG="$ccilog" MERGE_PUBLIC_ON_GREEN_LOG="$audit" \
            CR_PUBLIC_REPO="$TEST_REPO" PATH="$tmp/bin:$PATH" \
            bash "$tmp/scripts/merge-public-on-green.sh" "$pr" "${CLI_SHA:-${STUB_SHA-abc123def456}}" "$@" >/dev/null 2>"$tmp/err"
    fi
    rc=$?
    err=$(cat "$tmp/err" 2>/dev/null)

    LAST_GH_LOG="$ghlog"; LAST_AUDIT="$audit"; LAST_CHECKCI_LOG="$ccilog"
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
assert_checkci_has() {
    if grep -qF -- "$2" "$LAST_CHECKCI_LOG" 2>/dev/null; then pass; else fail "$1 (check-ci invocation log lacks '$2')"; fi
}
merge_line() { grep -E '^pr merge( |$)' "$LAST_GH_LOG" 2>/dev/null; }
assert_merge_has() {
    if merge_line | grep -qF -- "$2"; then pass
    else fail "$1 (pr merge invocation lacks '$2'; got: $(merge_line 2>/dev/null || echo '<no pr merge call>'))"; fi
}

echo "== merge-public-on-green.sh tests =="

# 1. Bad usage — missing sha positional arg entirely (only pr supplied).
tmp1=$(mktemp -d)
CLAUDECODE='' bash "$MPOG" 77 >/dev/null 2>"$tmp1/err"; rc=$?
if [ "$rc" -eq 1 ]; then pass; else fail "bad usage (no sha) → expected exit 1, got $rc"; fi
rm -rf "$tmp1"

# 2. Bad PR number (non-numeric).
tmp2=$(mktemp -d)
CLAUDECODE='' bash "$MPOG" abc abc1234 >/dev/null 2>"$tmp2/err"; rc=$?
if [ "$rc" -eq 1 ]; then pass; else fail "bad PR number → expected exit 1, got $rc"; fi
rm -rf "$tmp2"

# 3. Bad SHA (too short / non-hex).
tmp3=$(mktemp -d)
CLAUDECODE='' bash "$MPOG" 77 ab12 >/dev/null 2>"$tmp3/err"; rc=$?
if [ "$rc" -eq 1 ]; then pass; else fail "SHA too short → expected exit 1, got $rc"; fi
CLAUDECODE='' bash "$MPOG" 77 not-a-sha >/dev/null 2>"$tmp3/err"; rc=$?
if [ "$rc" -eq 1 ]; then pass; else fail "non-hex SHA → expected exit 1, got $rc"; fi
rm -rf "$tmp3"

# 4. Gate 0 — CLAUDECODE set (this test suite's OWN environment, and every
# other case above explicitly unset it) → immediate refusal, exit 19, BEFORE
# any gh call at all.
CLAUDECODE_SET=1 run_mpog 19 "CLAUDECODE set → exit 19 (agent self-refusal)"
if [ -s "$LAST_GH_LOG" ]; then fail "CLAUDECODE refusal made a gh call (should refuse before any API call)"; else pass; fi

# 5. gh 'no pull requests found' → refuse (exit 12), no merge attempted.
STUB_NO_PR=1 run_mpog 12 "no PR found → exit 12"
assert_gh_lacks "no-PR: no merge attempted" "pr merge"

# 6. PR query fails (auth/network) → refuse (exit 13).
STUB_STATE_FAIL=1 run_mpog 13 "gh pr view auth/network failure → exit 13"

# 7. PR resolves to a DIFFERENT repo than the pinned one → refuse (exit 10).
STUB_NWO="acme/other" run_mpog 10 "PR resolves to a non-pinned repo → exit 10"
assert_gh_lacks "wrong-repo: no merge attempted" "pr merge"

# 8. Empty head SHA in the meta query (API returns "") → refuse (exit 13). The
# operator's OWN CLI sha stays a valid shape (CLI_SHA) — this isolates "the API
# couldn't tell us the head" from "the operator's argument was malformed"
# (already covered by the standalone bad-SHA-shape tests above).
STUB_SHA="" CLI_SHA="abc123def456" run_mpog 13 "empty head SHA → exit 13"

# 9. PR not OPEN → refuse (exit 12), no merge.
STUB_STATE=CLOSED run_mpog 12 "PR not OPEN → exit 12"
assert_gh_lacks "not-open: no merge attempted" "pr merge"

# 10. Base-branch gate: PR base != repo default branch → refuse (exit 14).
STUB_BASE="some/other-branch" STUB_DEFAULT_BRANCH="main" run_mpog 14 "wrong base branch → exit 14"
assert_gh_lacks "wrong-base: no merge attempted" "pr merge"
assert_audit_has "wrong-base audits the reason" "reason=wrong-base-branch"

# 11. Undeterminable default branch → fail closed (exit 14).
STUB_DEFAULT_BRANCH="" run_mpog 14 "undeterminable default branch → exit 14 fail-closed"
assert_gh_lacks "undeterminable-default: no merge attempted" "pr merge"

# 12. Head-identity gate: operator SHA doesn't prefix-match the PR's real head
# → refuse (exit 15), "head moved", no merge, no check-ci call at all (fails
# BEFORE the CI watch — fast rejection of a stale operator command). Built by
# hand (not run_mpog, whose helper always passes the SAME sha as both the
# approved arg and the stubbed real head) so the approved/actual values differ.
tmp12=$(mktemp -d)
mkdir -p "$tmp12/scripts" "$tmp12/bin"
cp "$MPOG" "$tmp12/scripts/merge-public-on-green.sh"
# A stub that FAILS LOUDLY if ever reached (exit 99, distinguishable from every
# real gate code) — deliberately NOT the real check-ci.sh: if gate ordering ever
# regresses so gate 4 runs before gate 3 refuses, this must fail fast, not hang
# trying to reach real GitHub.
printf '#!/usr/bin/env bash\necho "check-ci stub: should never be reached (gate 3 must refuse first)" >&2\nexit 99\n' > "$tmp12/scripts/check-ci.sh"
chmod +x "$tmp12/scripts/check-ci.sh"
cat > "$tmp12/bin/gh" <<'STUB'
#!/usr/bin/env bash
verb="$1 $2"
case "$verb" in
    "pr view") printf 'OPEN|https://github.com/acme/pub/pull/77|77|deadbeef01|main' ;;
    "repo view") printf 'main' ;;
    *) exit 90 ;;
esac
exit 0
STUB
chmod +x "$tmp12/bin/gh"
CLAUDECODE='' CR_PUBLIC_REPO="acme/pub" PATH="$tmp12/bin:$PATH" \
    bash "$tmp12/scripts/merge-public-on-green.sh" 77 cafefeed0123 >/dev/null 2>"$tmp12/err"
rc=$?
if [ "$rc" -eq 15 ]; then pass; else fail "mismatched approved-sha vs real head → expected exit 15, got $rc"; fi
rm -rf "$tmp12"

# 13. check-ci not found → refuse (exit 16).
NO_CHECK_CI=1 run_mpog 16 "missing check-ci → exit 16"

# 14. check-ci non-green (exit 3) → refuse (exit 16), no merge; the SELECTOR
# passed to check-ci.sh is the PR's full URL (cwd-independence — this script
# runs from the bridge's HIMMEL_REPO cwd, which is NOT the public repo).
STUB_CI_RC=3 run_mpog 16 "check-ci exit 3 → exit 16"
assert_gh_lacks "non-green: no merge attempted" "pr merge"
assert_checkci_has "check-ci invoked with the PR's full URL, not a bare number" "https://github.com/acme/pub/pull/77"

# 14b. Review state changes AFTER check-ci certifies but BEFORE merge (codex-adv
# review-race): gate 4 passes (STUB_CI_RC=0) but the fresh gate-4c
# `--threads-only` re-check fails → refuse (exit 16), no merge — closes the
# window where --admin could bypass a newly-blocking review.
STUB_SHA="feedface9999" STUB_THREADS_RC=3 run_mpog 16 "review blocked after the gate → exit 16"
assert_gh_lacks "review-race: no merge attempted" "pr merge"
assert_audit_has "review-race audits the reason" "reason=review-blocked-premerge"

# 15. Base retargeted during the CI wait (HIMMEL-1080 lesson, ported): base OK
# at the initial gate but changed by the pre-merge re-verify → refuse (exit 14).
STUB_BASE="main" STUB_DEFAULT_BRANCH="main" STUB_BASE_PREMERGE="some/other-branch" \
    run_mpog 14 "base retargeted after the gate → exit 14"
assert_gh_lacks "retargeted-base: no merge attempted" "pr merge"
assert_audit_has "retargeted-base audits the reason" "reason=base-branch-changed"

# 16. Head moved during the CI wait → refuse (exit 15), no merge.
STUB_SHA="abc123def456" STUB_SHA_PREMERGE="feedface9999" \
    run_mpog 15 "head moved during the CI wait → exit 15"
assert_gh_lacks "head-moved-premerge: no merge attempted" "pr merge"
assert_audit_has "head-moved-premerge audits the reason" "reason=head-moved-premerge"

# 17. Audit sink not writable → refuse BEFORE merging (exit 17), no merge.
STUB_AUDIT_UNWRITABLE=1 run_mpog 17 "unwritable audit sink → exit 17"
assert_gh_lacks "unwritable-audit: no merge attempted" "pr merge"

# 17b. No RESOLVABLE audit sink (not a git repo + no MERGE_PUBLIC_ON_GREEN_LOG)
# → refuse at preflight (exit 17) even with all gates green: an unauditable merge
# must not proceed. Regression guard for the fail-open gap (codex CR-3) where an
# empty sink used to pass preflight and merge with stdout-only audit.
STUB_SHA="feedface9999" STUB_AUDIT_NOSINK=1 run_mpog 17 "no resolvable audit sink → exit 17"
assert_gh_lacks "no-sink: no merge attempted" "pr merge"

# 18. All gates pass → merge (exit 0) with --squash --admin + the FRESH
# (pre-merge re-verified) head SHA pinned via --match-head-commit.
STUB_SHA="feedface9999" STUB_NWO="acme/pub" run_mpog 0 "all gates pass → merged"
assert_merge_has "merge uses --squash"                    "--squash"
assert_merge_has "merge uses --admin"                      "--admin"
assert_merge_has "merge pins the certified (fresh) head sha" "--match-head-commit feedface9999"
assert_gh_has  "merge scoped to the pinned repo via --repo" "--repo acme/pub"
assert_audit_has "audit records MERGING intent" "MERGING"
assert_audit_has "audit records MERGED + sha"   "MERGED"

# 19. --dry-run: gates pass but NO merge fires.
STUB_SHA="feedface9999" run_mpog 0 "dry-run passes gates, no merge" 77 -- --dry-run
assert_gh_lacks  "dry-run does not merge" "pr merge"
assert_audit_has "dry-run audits DRYRUN"  "DRYRUN"

# 20. gh pr merge fails (head moved / conflict at the final call) → exit 18.
STUB_SHA="feedface9999" STUB_MERGE_FAIL=1 run_mpog 18 "merge failure → exit 18"

# 21. gh ACCEPTS the merge but the PR never reports MERGED → exit 18 (a zero
# rc from gh is "accepted", never "merged" outright — poll to confirm).
STUB_SHA="feedface9999" STUB_POST_STATE=CLOSED run_mpog 18 "merge accepted but PR not MERGED → exit 18"
assert_audit_has "unconfirmed merge audits the refusal" "reason=merge-unconfirmed"

# 22. --help works (and does not require valid pr/sha args, or even a repo).
help_out=$(CLAUDECODE='' bash "$MPOG" --help 2>&1)
help_rc=$?
if [ "$help_rc" -eq 0 ]; then pass; else fail "--help exits 0 (got $help_rc)"; fi
for _code in 0 1 10 11 12 13 14 15 16 17 18 19; do
    if printf '%s' "$help_out" | grep -qE "^ *${_code} +[A-Za-z]"; then pass
    else fail "--help documents exit code ${_code}"; fi
done
for _doc in CR_PUBLIC_REPO MERGE_PUBLIC_ON_GREEN_LOG 'GATE INTEGRITY' CLAUDECODE; do
    if printf '%s' "$help_out" | grep -q "$_doc"; then pass
    else fail "--help includes $_doc"; fi
done
if printf '%s' "$help_out" | grep -q 'set -uo pipefail'; then
    fail "--help leaks the 'set -uo pipefail' code line"
else
    pass
fi

echo
echo "merge-public-on-green: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
