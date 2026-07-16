#!/usr/bin/env bash
# Tests for handover/merge-on-green.sh — the HIMMEL-1042 armed-chain auto-merge
# chokepoint. The wrapper has NO env seams for `gh`/`check-ci` (gate integrity,
# coderabbit): so each case runs a COPY of the script in a temp tree
# ($tmp/scripts/handover/merge-on-green.sh) with a stub check-ci at the fixed
# sibling path ($tmp/scripts/check-ci.sh) and a stub `gh` FIRST on PATH. Asserts
# the fail-closed gate sequence + that a real merge only ever fires with
# --squash + --match-head-commit <certified-sha>.
set -uo pipefail

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
#   STUB_CI_RC          exit code of the stub check-ci. Default 0.
#   STUB_MERGE_FAIL=1   `gh pr merge` exits 1 (generic failure).
#   STUB_MERGE_COSMETIC=1  `gh pr merge` exits 1 with the held-worktree message.
#   STUB_POST_STATE     PR state the post-merge re-query returns. Default MERGED.
#   NO_CHECK_CI=1       omit the stub check-ci (sibling path absent).
#   STUB_AUDIT_UNWRITABLE=1  point the audit sink at an unwritable path.
# After the run: $LAST_GH_LOG = stub gh argv log, $LAST_AUDIT = audit log.
LAST_GH_LOG=""; LAST_AUDIT=""
run_mog() {
    local expected="$1" name="$2"; shift 2
    [ "${1:-}" = "--" ] && shift
    local tmp; tmp=$(mktemp -d)
    local ghlog="$tmp/gh.log"; : > "$ghlog"
    local audit="$tmp/audit.log"
    [ "${STUB_AUDIT_UNWRITABLE:-0}" = "1" ] && audit="$tmp/nodir/audit.log"  # parent absent → unwritable

    # Copy the script into a temp tree so its fixed `../check-ci.sh` sibling
    # resolves to our stub — no CHECK_CI env override exists any more.
    mkdir -p "$tmp/scripts/handover" "$tmp/bin"
    cp "$MOG" "$tmp/scripts/handover/merge-on-green.sh"
    if [ "${NO_CHECK_CI:-0}" != "1" ]; then
        printf '#!/usr/bin/env bash\nexit %s\n' "${STUB_CI_RC:-0}" > "$tmp/scripts/check-ci.sh"
        chmod +x "$tmp/scripts/check-ci.sh"
    fi

    # Stub `gh`, FIRST on PATH (no GH_CMD seam). FAILS CLOSED (coderabbit-1): an
    # unsupported verb or an unrecognized --json query exits non-zero rather than
    # falling through to a silent success — otherwise a wrapper that grew a new gh
    # call would be "tested" against a stub that rubber-stamps anything.
    cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
verb="$1 $2"
json=""
while [ $# -gt 0 ]; do case "$1" in --json) json="${2:-}";; esac; shift; done
nwo="${STUB_NWO:-owner/repo}"
case "$verb" in
    "pr view")
        [ "${STUB_NO_PR:-0}" = "1" ] && { echo 'no pull requests found for branch "x"' >&2; exit 1; }
        [ "${STUB_STATE_FAIL:-0}" = "1" ] && { echo "gh: api error" >&2; exit 1; }
        case "$json" in
            "state,url,number,headRefOid")
                # Consolidated meta query (codex-1 fix): state|url|number|headRefOid.
                printf '%s|https://github.com/%s/pull/%s|%s|%s' \
                    "${STUB_STATE-OPEN}" "$nwo" "${STUB_NUM:-77}" "${STUB_NUM:-77}" "${STUB_SHA-abc123def456}" ;;
            "state")
                # Post-merge re-query: the cosmetic branch-delete path AND the
                # merge-confirmation poll on the success path (coderabbit).
                printf '%s' "${STUB_POST_STATE:-MERGED}" ;;
            *) echo "gh stub: unhandled 'pr view' query: --json '$json'" >&2; exit 90 ;;
        esac
        ;;
    "repo view")
        # isPrivate is keyed off the repo POSITIONAL ($3) — the PR's own repo,
        # not cwd (codex-1). nameWithOwner (no positional) = the CURRENT checkout
        # for the same-repo binding (codex-adv-2).
        case "$json" in
            isPrivate)     printf '%s' "${STUB_PRIVATE-true}" ;;
            nameWithOwner)
                [ "${STUB_CWD_FAIL:-0}" = "1" ] && { echo "gh: api error" >&2; exit 1; }
                printf '%s' "${STUB_CWD_NWO:-${STUB_NWO:-owner/repo}}" ;;
            *) echo "gh stub: unhandled 'repo view' query: --json '$json'" >&2; exit 90 ;;
        esac
        ;;
    "pr merge")
        [ "${STUB_MERGE_FAIL:-0}" = "1" ] && { echo "merge conflict / head moved" >&2; exit 1; }
        if [ "${STUB_MERGE_COSMETIC:-0}" = "1" ]; then
            echo "failed to run git: fatal: 'main' is already used by worktree at '/x'" >&2
            exit 1
        fi
        echo "merged"
        ;;
    *) echo "gh stub: unsupported command: $*" >&2; exit 90 ;;
esac
exit 0
STUB
    chmod +x "$tmp/bin/gh"

    local err rc
    GH_LOG="$ghlog" MERGE_ON_GREEN_LOG="$audit" PATH="$tmp/bin:$PATH" \
          bash "$tmp/scripts/handover/merge-on-green.sh" "$@" >/dev/null 2>"$tmp/err"
    rc=$?
    err=$(cat "$tmp/err" 2>/dev/null)

    LAST_GH_LOG="$ghlog"; LAST_AUDIT="$audit"
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
# Scope merge-flag assertions to the `pr merge` invocation itself (coderabbit-1).
# Searching the whole GH_LOG would let a flag appearing in ANY other gh call
# satisfy an assertion about how the MERGE was invoked — which is the one thing
# these assertions exist to prove.
merge_line() { grep -E '^pr merge( |$)' "$LAST_GH_LOG" 2>/dev/null; }
assert_merge_has() {
    if merge_line | grep -qF -- "$2"; then pass
    else fail "$1 (pr merge invocation lacks '$2'; got: $(merge_line 2>/dev/null || echo '<no pr merge call>'))"; fi
}
# Assert a post-merge state RE-QUERY happened (coderabbit). A literal
# "pr view --json state" would also match the initial metadata query
# (`--json state,url,number,headRefOid`) as a substring, so the assertion would
# pass even with post-merge confirmation removed entirely — vacuously guarding
# the one behavior it exists to prove. Anchor on a word boundary after `state`
# so only the state-ONLY query matches.
assert_state_requery() {
    if grep -Eq '^pr view( .*)? --json state( |$)' "$LAST_GH_LOG"; then pass
    else fail "$1 (no post-merge 'pr view --json state' re-query found)"; fi
}

echo "== merge-on-green.sh tests =="

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
assert_merge_has "merge deletes the source branch"  "--delete-branch"
# codex-1 regression: the privacy check targets the PR's OWN repo, not cwd.
assert_gh_has  "privacy check scoped to the PR repo" "repo view acme/private-repo"
assert_audit_has "audit records MERGING intent"   "MERGING"
assert_audit_has "audit records MERGED + sha"     "MERGED"
assert_audit_has "audit records the certified sha" "sha=feedface99"

# 10. --dry-run: gates pass but NO merge fires.
run_mog 0 "dry-run passes gates, no merge" -- --dry-run
assert_gh_lacks  "dry-run does not merge"   "pr merge"
assert_audit_has "dry-run audits DRYRUN"    "DRYRUN"

# 11. gh pr merge fails (head moved / conflict) → exit 15.
STUB_MERGE_FAIL=1 run_mog 15 "merge failure → exit 15"

# 11b. Cosmetic branch-delete fail + PR confirmed MERGED → success (exit 0).
STUB_SHA="cafe01" STUB_MERGE_COSMETIC=1 STUB_POST_STATE=MERGED run_mog 0 "cosmetic fail + PR MERGED → exit 0"
assert_state_requery "cosmetic path re-queries PR state"
assert_audit_has "cosmetic-merged path records MERGED" "MERGED"

# 11c. Cosmetic branch-delete fail but PR still OPEN → NOT merged (exit 15).
# The 'used by worktree' phrase must NOT be inferred as a completed merge
# (coderabbit): the merge did not land, so fail.
STUB_MERGE_COSMETIC=1 STUB_POST_STATE=OPEN run_mog 15 "cosmetic fail + PR still OPEN → exit 15"

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

# 12. A truthy-but-not-1 opt-in also enables (yes/on/true).
ARMAUTOMERGE=yes run_mog 0 "ARMAUTOMERGE=yes also enables"

echo
echo "merge-on-green: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
