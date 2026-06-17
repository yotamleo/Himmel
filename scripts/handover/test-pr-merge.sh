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
#   STUB_VIEW_FAIL=1   : `gh pr view` (mergeability poll) exits 1 — simulates
#                        a transient gh/network failure (HIMMEL-179).
#   STUB_VIEW_MERGEABLE: value `gh pr view` prints for `.mergeable`. Default
#                        MERGEABLE. Set CONFLICTING / UNKNOWN to drive the poll.
#   STUB_VIEW_UNKNOWN_THEN=N : first N `gh pr view` calls print UNKNOWN, then
#                        MERGEABLE — exercises the retry-then-settle path. Uses
#                        a counter file at $GH_VIEW_COUNT.
# After the run, $LAST_GH_LOG holds the path to the recorded gh argv log so
# callers can assert on --admin presence/absence.
LAST_GH_LOG=""
LAST_OUT=""
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
        # Mergeability poll (HIMMEL-179). pr-merge calls:
        #   gh pr view <pr> --json mergeable --jq '.mergeable'
        if [ "${STUB_VIEW_FAIL:-0}" = "1" ]; then
            echo "gh: could not resolve PR" >&2
            exit 1
        fi
        if [ "${STUB_VIEW_UNKNOWN_THEN:-0}" != "0" ]; then
            n=0
            [ -f "$GH_VIEW_COUNT" ] && n=$(cat "$GH_VIEW_COUNT")
            n=$((n + 1))
            echo "$n" > "$GH_VIEW_COUNT"
            if [ "$n" -le "$STUB_VIEW_UNKNOWN_THEN" ]; then
                echo "UNKNOWN"
            else
                echo "MERGEABLE"
            fi
        else
            echo "${STUB_VIEW_MERGEABLE:-MERGEABLE}"
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
        git checkout -q -b "$branch" 2>/dev/null || git checkout -q "$branch"
        # Forge seam (HIMMEL-326): pr-merge resolves the forge from origin. A
        # github origin selects the github backend, which reproduces the exact
        # `gh pr merge` shapes (incl. --admin fallback) these asserts expect.
        git remote add origin https://github.com/test/test.git
        GH_LOG="$ghlog" GH_VIEW_COUNT="$tmp/view.count" \
            PATH="$tmp/bin:$PATH" GH_CMD=gh \
            PR_MERGE_POLL_INTERVAL="${PR_MERGE_POLL_INTERVAL:-0}" \
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

# --- mergeability poll (HIMMEL-179 sharp#1) ---

# (a) MERGEABLE immediately => merges after a single poll.
if STUB_VIEW_MERGEABLE=MERGEABLE \
    run_case "handover/x-slug" 0 "poll: MERGEABLE merges"; then
    assert_log_has "pr view 42 --json mergeable" "poll queried mergeability"
    assert_log_has "pr merge 42 --squash"        "MERGEABLE proceeds to merge"
fi

# (b) UNKNOWN twice then MERGEABLE => merges after the poll settles.
if STUB_VIEW_UNKNOWN_THEN=2 \
    run_case "handover/x-slug" 0 "poll: UNKNOWN-then-MERGEABLE merges"; then
    assert_log_has "pr merge 42 --squash" "settled UNKNOWN proceeds to merge"
fi

# (c) CONFLICTING => exit 4, no merge attempted.
if STUB_VIEW_MERGEABLE=CONFLICTING \
    run_case "handover/x-slug" 4 "poll: CONFLICTING exits 4"; then
    assert_log_lacks "pr merge" "CONFLICTING does not attempt merge"
fi

# (d) UNKNOWN never settles (attempts exhausted) => falls through to merge.
if STUB_VIEW_MERGEABLE=UNKNOWN PR_MERGE_POLL_ATTEMPTS=3 \
    run_case "handover/x-slug" 0 "poll: UNKNOWN exhausted falls through to merge"; then
    assert_log_has "pr merge 42 --squash" "exhausted UNKNOWN still attempts merge"
fi

# (e) gh pr view itself fails => skips poll, falls through to merge.
if STUB_VIEW_FAIL=1 \
    run_case "handover/x-slug" 0 "poll: gh pr view failure falls through to merge"; then
    assert_log_has "pr merge 42 --squash" "view failure still attempts merge"
fi

# --- summary ---
echo "  pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "PASS"
exit 0
