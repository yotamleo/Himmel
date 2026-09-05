#!/usr/bin/env bash
# Smoke test for scripts/hooks/trigger-cr-on-push.sh (HIMMEL-1906).
#
# HIMMEL-1906: a push that advances an open PR's head must re-trigger
# CodeRabbit at most ONCE per head SHA — this is the fix for the bug where
# trigger-cr-on-pr-create.sh's old per-PR dedup silently blackholed every fix
# round after the first review (PRs #1717/#1718). This suite exercises the
# hook with a STUBBED `gh` on PATH (no network) and the shared ledger
# (scripts/lib/cr-trigger-ledger.sh) redirected to a throwaway file via
# CR_TRIGGER_LEDGER_PATH, so no test writes into this repo's real .git/.
#
# Covers (acceptance, per the HIMMEL-1906 brief):
#   1. first trigger on a head -> posts, records the SHA
#   2. second request on the SAME head -> no-op, no second comment
#   3. a new head after a push -> posts (the whole point)
#   4. ledger missing/unwritable -> fails open, does not strand the push
#   5. malformed / degraded hook input -> exit 0 (silently, or with a warning)
# Plus the surrounding guard behaviour (fast-path, anchoring, no-PR, closed
# PR, gh missing, post failure) mirroring test-trigger-cr-on-pr-create.sh's
# style.
set -euo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/trigger-cr-on-push.sh"

# This SUITE requires jq: run_hook builds every payload with `jq -n --arg` so
# the command string is properly JSON-escaped. The HOOK degrades gracefully
# without jq (test 10 exercises exactly that path) but the harness does not.
if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not found — this suite needs jq to build JSON-escaped test payloads" >&2
    exit 0
fi

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

# See test-trigger-cr-on-pr-create.sh for why TMP_ROOT is deliberately NOT
# cygpath-converted: a stubbed `gh` needs to win the PATH lookup over any real
# `gh`, and Git Bash won't search a mixed `C:/…` PATH entry.
TMP_ROOT=$(mktemp -d)

# ─── stubbed gh (no network) ────────────────────────────────────────────────
# Dispatches on the subcommand the hook issues:
#   gh pr view --json ...                      -> $FAKE_GH_PR_VIEW_JSON, or
#                                                  exit 1 if unset (no PR for
#                                                  the branch — the common case)
#   gh api repos/<o>/<r>/issues/<n>/comments   -> dump $FAKE_GH_COMMENTS_FILE
#                                                  (the push hook does NOT call
#                                                  this in normal operation —
#                                                  see scan_existing=0 in the
#                                                  hook — stubbed defensively)
#   gh pr comment <n> --repo <o>/<r> --body X  -> append X to $FAKE_GH_COMMENT_LOG
#                                                  (exit 1 if FAKE_GH_COMMENT_FAIL=1)
GHSTUB_DIR="$TMP_ROOT/ghbin"
mkdir -p "$GHSTUB_DIR"
cat > "$GHSTUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
    if [ -n "${FAKE_GH_PR_VIEW_JSON:-}" ]; then
        printf '%s\n' "$FAKE_GH_PR_VIEW_JSON"
        exit 0
    fi
    exit 1
fi
if [ "${1:-}" = "api" ]; then
    cat "${FAKE_GH_COMMENTS_FILE:-/dev/null}" 2>/dev/null || true
    exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "comment" ]; then
    if [ "${FAKE_GH_COMMENT_FAIL:-0}" = "1" ]; then
        echo "fake gh: simulated comment failure" >&2
        exit 1
    fi
    body=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --body) body="${2:-}"; shift ;;
        esac
        shift
    done
    printf '%s\n' "$body" >> "${FAKE_GH_COMMENT_LOG:?}"
    exit 0
fi
exit 0
STUB
chmod +x "$GHSTUB_DIR/gh"
export PATH="$GHSTUB_DIR:$PATH"

COMMENT_LOG="$TMP_ROOT/comment.log"
COMMENTS_FILE="$TMP_ROOT/existing.txt"
LEDGER_PATH="$TMP_ROOT/cr-triggered-heads"
export FAKE_GH_COMMENT_LOG="$COMMENT_LOG"
export FAKE_GH_COMMENTS_FILE="$COMMENTS_FILE"
export CR_TRIGGER_LEDGER_PATH="$LEDGER_PATH"

# Foreign-repo guard (HIMMEL-2034): the hook now posts only on a repo whose
# CodeRabbit gate is ours — the cwd's armed origin, or a repo named in
# CR_TRIGGER_REPOS. Every fixture below is a PR on acme/widget, which is
# nobody's origin, so allowlist it once here; the foreign-repo test overrides
# this to an unrelated value to exercise the refusal.
export CR_TRIGGER_REPOS="acme/widget"

# Per-test reset.
reset_state() {
    : > "$COMMENT_LOG"
    : > "$COMMENTS_FILE"
    export FAKE_GH_COMMENT_FAIL=0
    rm -f "$LEDGER_PATH"
    unset FAKE_GH_PR_VIEW_JSON 2>/dev/null || true
}

# pr_view_json <num> <sha> <state> <url> -- builds the `gh pr view --json` blob.
pr_view_json() {
    jq -nc --argjson num "$1" --arg sha "$2" --arg state "$3" --arg url "$4" \
        '{number:$num, headRefOid:$sha, state:$state, url:$url}'
}

# Run the hook with a given command string, capturing its exit code in `rc`.
run_hook() {
    local command_str="$1"
    local payload
    payload=$(jq -nc --arg cmd "$command_str" \
        '{tool_name:"Bash",tool_input:{command:$cmd},tool_response:{stdout:"",stderr:""}}')
    rc=0
    out=$(printf '%s' "$payload" | bash "$HOOK" 2>&1) || rc=$?
}

posted_count() { wc -l < "$COMMENT_LOG" 2>/dev/null | tr -d ' ' || echo 0; }

# Test 1: first trigger on a head -> posts, records the SHA ------------------
echo "TEST: git push advancing an open PR's head -> POSTS and records the SHA"
reset_state
FAKE_GH_PR_VIEW_JSON=$(pr_view_json 301 "sha-aaa111" "OPEN" "https://github.com/acme/widget/pull/301")
export FAKE_GH_PR_VIEW_JSON
run_hook "git push"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 1 ] && grep -qxF "acme/widget 301 sha-aaa111" "$LEDGER_PATH"; then
    if grep -q '@coderabbitai review' "$COMMENT_LOG"; then
        pass "posted once and recorded the new head in the ledger"
    else
        fail "posted, but body was not '@coderabbitai review'" "$(cat "$COMMENT_LOG")"
    fi
else
    fail "expected rc=0, 1 post, SHA in ledger" "out: $out; ledger: $(cat "$LEDGER_PATH" 2>/dev/null)"
fi

# Test 2: second request on the SAME head -> no-op, no second comment --------
echo "TEST: a second push event with the SAME head -> ledger no-op"
reset_state
FAKE_GH_PR_VIEW_JSON=$(pr_view_json 302 "sha-bbb222" "OPEN" "https://github.com/acme/widget/pull/302")
export FAKE_GH_PR_VIEW_JSON
run_hook "git push"
first_rc=$rc
run_hook "git push --force-with-lease"
if [ "$first_rc" -eq 0 ] && [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 1 ]; then
    pass "the same head triggered exactly one post across two push events"
else
    fail "expected exactly 1 post for the same head across two pushes, got posted=$(posted_count)" "out: $out"
fi

# Test 3: a NEW head after a push -> posts again (the whole point) -----------
echo "TEST: a push that advances the head to a NEW SHA -> POSTS AGAIN"
reset_state
FAKE_GH_PR_VIEW_JSON=$(pr_view_json 303 "sha-ccc333" "OPEN" "https://github.com/acme/widget/pull/303")
export FAKE_GH_PR_VIEW_JSON
run_hook "git push"
FAKE_GH_PR_VIEW_JSON=$(pr_view_json 303 "sha-ddd444" "OPEN" "https://github.com/acme/widget/pull/303")
export FAKE_GH_PR_VIEW_JSON
run_hook "git push"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 2 ] \
    && grep -qxF "acme/widget 303 sha-ccc333" "$LEDGER_PATH" && grep -qxF "acme/widget 303 sha-ddd444" "$LEDGER_PATH"; then
    pass "a new head after a push triggered a second, independent post — this is the fix"
else
    fail "expected 2 posts (one per distinct head), got posted=$(posted_count)" "out: $out; ledger: $(cat "$LEDGER_PATH" 2>/dev/null)"
fi

# Test 3b: a stale @coderabbitai comment from the FIRST head does not block --
# the SECOND head's legitimate trigger. This is the exact bug HIMMEL-1906
# fixes: the per-PR comment scan is repo-wide, not per-head, so it must not
# gate the push path (see scan_existing=0 in the hook / cr-trigger-ledger.sh).
echo "TEST: a stale trigger comment from an OLDER head does not block a NEW head's trigger"
reset_state
printf '@coderabbitai review\n' > "$COMMENTS_FILE"
FAKE_GH_PR_VIEW_JSON=$(pr_view_json 304 "sha-eee555" "OPEN" "https://github.com/acme/widget/pull/304")
export FAKE_GH_PR_VIEW_JSON
run_hook "git push"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 1 ]; then
    pass "posted for the new head despite a stale comment from a prior head existing on the PR"
else
    fail "expected the new head to post despite a stale existing comment, got posted=$(posted_count)" "out: $out"
fi

# Test 3c: two DIFFERENT PRs sharing ONE head SHA -> BOTH trigger (F1 crux) --
# Keying the ledger by SHA alone (the pre-CR-round-2 bug) let triggering PR
# #315 silently suppress PR #316's trigger, even though they are different
# PRs — reachable via stacked branches / the same commit pushed to two
# branches / a reopened PR. This test FAILS against a SHA-only key.
echo "TEST: two different PRs sharing the SAME head SHA -> BOTH post (F1)"
reset_state
FAKE_GH_PR_VIEW_JSON=$(pr_view_json 315 "sha-shared999" "OPEN" "https://github.com/acme/widget/pull/315")
export FAKE_GH_PR_VIEW_JSON
run_hook "git push"
first_rc=$rc
FAKE_GH_PR_VIEW_JSON=$(pr_view_json 316 "sha-shared999" "OPEN" "https://github.com/acme/widget/pull/316")
export FAKE_GH_PR_VIEW_JSON
run_hook "git push"
if [ "$first_rc" -eq 0 ] && [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 2 ] \
    && grep -qxF "acme/widget 315 sha-shared999" "$LEDGER_PATH" \
    && grep -qxF "acme/widget 316 sha-shared999" "$LEDGER_PATH"; then
    pass "both PRs #315 and #316 triggered independently despite sharing a head SHA"
else
    fail "expected 2 posts (one per PR) for the same shared head SHA, got posted=$(posted_count)" "out: $out; ledger: $(cat "$LEDGER_PATH" 2>/dev/null)"
fi

# Test 4: ledger unwritable -> fails open, does not strand the push ----------
# Point the ledger at a path whose PARENT is a plain FILE, so the append
# always fails deterministically (no chmod — unreliable on Git Bash/Windows).
# cr_trigger_post_review must still post and only WARN that the record
# couldn't be written, never suppress the review.
echo "TEST: ledger directory unwritable -> still posts (fails open, never strands the push)"
reset_state
BLOCKED="$TMP_ROOT/blocked_file"
: > "$BLOCKED"
export CR_TRIGGER_LEDGER_PATH="$BLOCKED/cr-triggered-heads"
FAKE_GH_PR_VIEW_JSON=$(pr_view_json 305 "sha-fff666" "OPEN" "https://github.com/acme/widget/pull/305")
export FAKE_GH_PR_VIEW_JSON
run_hook "git push"
export CR_TRIGGER_LEDGER_PATH="$LEDGER_PATH"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 1 ] && grepq "$out" 'could not record head'; then
    pass "an unwritable ledger did not strand the trigger — the comment still posted, and the failed record was warned"
else
    fail "expected rc=0, 1 post, and a could-not-record warning despite an unwritable ledger, got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 5: no PR for the current branch -> quiet no-op -------------------------
echo "TEST: no open PR for the branch -> quiet no-op (the common pre-PR-create case)"
reset_state
run_hook "git push"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 0 ]; then
    pass "no PR found -> posted nothing"
else
    fail "expected rc=0 and 0 posts when there is no PR, got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 6: PR is CLOSED/MERGED -> no post --------------------------------------
echo "TEST: PR is not OPEN -> no post"
reset_state
FAKE_GH_PR_VIEW_JSON=$(pr_view_json 306 "sha-ggg777" "MERGED" "https://github.com/acme/widget/pull/306")
export FAKE_GH_PR_VIEW_JSON
run_hook "git push"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 0 ]; then
    pass "posted nothing for a MERGED PR"
else
    fail "expected rc=0 and 0 posts for a non-OPEN PR, got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 7: unrelated command -> fast-path exit, no post ------------------------
echo "TEST: unrelated command -> fast-path exit, no post"
reset_state
FAKE_GH_PR_VIEW_JSON=$(pr_view_json 307 "sha-hhh888" "OPEN" "https://github.com/acme/widget/pull/307")
export FAKE_GH_PR_VIEW_JSON
run_hook "git status"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 0 ]; then
    pass "posted nothing for a non-git-push command"
else
    fail "expected rc=0 and 0 posts, got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 8: anchoring — echo string literal -> no post --------------------------
echo "TEST: echo \"git push …\" (string literal, not command position) -> no post"
reset_state
FAKE_GH_PR_VIEW_JSON=$(pr_view_json 308 "sha-iii999" "OPEN" "https://github.com/acme/widget/pull/308")
export FAKE_GH_PR_VIEW_JSON
run_hook 'echo "git push origin main"'
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 0 ]; then
    pass "did not post for a git-push string inside echo"
else
    fail "expected rc=0 and 0 posts, got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 9: post-failure stays non-blocking -------------------------------------
echo "TEST: comment post fails -> hook stays non-blocking (rc 0)"
reset_state
FAKE_GH_PR_VIEW_JSON=$(pr_view_json 309 "sha-jjj000" "OPEN" "https://github.com/acme/widget/pull/309")
export FAKE_GH_PR_VIEW_JSON
export FAKE_GH_COMMENT_FAIL=1
run_hook "git push"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 0 ]; then
    pass "post-failure is non-blocking (rc 0) and records nothing"
else
    fail "expected rc=0 (non-blocking) on post failure, got rc=$rc" "out: $out"
fi
export FAKE_GH_COMMENT_FAIL=0

# Test 10: jq absent -> no post, warns ----------------------------------------
echo "TEST: jq absent -> no post, warns (malformed/degraded input -> exit 0 with a warning)"
reset_state
FAKE_GH_PR_VIEW_JSON=$(pr_view_json 310 "sha-kkk111" "OPEN" "https://github.com/acme/widget/pull/310")
export FAKE_GH_PR_VIEW_JSON
NOJQ_BIN="$TMP_ROOT/nojqbin"
mkdir -p "$NOJQ_BIN"
REAL_BASH=$(command -v bash)
for tool in bash cat grep head tail sed dirname; do
    real=$(command -v "$tool")
    printf '#!%s\nexec %s "$@"\n' "$REAL_BASH" "$real" > "$NOJQ_BIN/$tool"
    chmod +x "$NOJQ_BIN/$tool"
done
nojq_payload=$(jq -nc --arg cmd 'git push' \
    '{tool_name:"Bash",tool_input:{command:$cmd},tool_response:{stdout:"",stderr:""}}')
rc=0
out=$(printf '%s' "$nojq_payload" | env PATH="$NOJQ_BIN:$GHSTUB_DIR" "$REAL_BASH" "$HOOK" 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 0 ] && grepq "$out" 'jq not in PATH'; then
    pass "no-jq run posted nothing and warned about the missing jq"
else
    fail "expected rc=0, 0 posts, and a 'jq not in PATH' warning; got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 11: malformed JSON payload (but matches the fast path) -> exit 0, no post
echo "TEST: malformed JSON input -> exit 0, no post (fails open, never strands the push)"
reset_state
FAKE_GH_PR_VIEW_JSON=$(pr_view_json 311 "sha-lll222" "OPEN" "https://github.com/acme/widget/pull/311")
export FAKE_GH_PR_VIEW_JSON
rc=0
out=$(printf 'not valid json but mentions git push\n' | bash "$HOOK" 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 0 ]; then
    pass "malformed JSON input exited 0 and posted nothing"
else
    fail "expected rc=0 and 0 posts for malformed JSON, got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 12: `git`/`push` split across a `\`-continuation -> POSTS (F3) --------
# `[[:space:]]+` between the two tokens can't cross the literal backslash
# byte a line continuation leaves behind, so a real `git push` written as
#   git \
#     push origin main
# (an ordinary shape for a long invocation) used to never fire. Single-
# quoted literal spanning two lines, same style as the sibling suite's
# multi-line `gh pr create` test.
echo "TEST: git/push split across a backslash-continuation (multi-line) -> POSTS"
reset_state
FAKE_GH_PR_VIEW_JSON=$(pr_view_json 312 "sha-nnn444" "OPEN" "https://github.com/acme/widget/pull/312")
export FAKE_GH_PR_VIEW_JSON
run_hook 'git \
  push origin main'
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 1 ]; then
    pass "posted for git/push split across a line continuation"
else
    fail "expected rc=0 and 1 post for a continuation-split git push, got rc=$rc posted=$(posted_count)" "out: $out"
fi


# Test F: a push advancing a PR on a FOREIGN repo -> NO post, advisory -------
# HIMMEL-2034: the same exposure as the `gh pr create` hook — a push to an
# upstream/fork branch advances a PR that is not ours to summon CodeRabbit on.
# The guard lives in cr_trigger_post_review (scripts/lib/cr-trigger-ledger.sh),
# the one seam both hooks post through; this asserts it holds from here.
echo "TEST: push advancing a FOREIGN repo's PR -> no post, advisory on stderr"
reset_state
saved_allow="$CR_TRIGGER_REPOS"
export CR_TRIGGER_REPOS="acme/widget"
FAKE_GH_PR_VIEW_JSON=$(pr_view_json 896 "sha-foreign" "OPEN" "https://github.com/upstream/notours/pull/896")
export FAKE_GH_PR_VIEW_JSON
run_hook "git push"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 0 ] && grepq "$out" -F 'not triggering CodeRabbit'     && grepq "$out" -F 'hermes/codex critic' && [ ! -s "$LEDGER_PATH" ]; then
    pass "foreign-repo push: posted nothing, recorded nothing, advised the critic path"
else
    fail "expected rc=0, 0 posts, empty ledger and a foreign-repo advisory, got rc=$rc posted=$(posted_count)" "out: $out; ledger: $(cat "$LEDGER_PATH" 2>/dev/null)"
fi
export CR_TRIGGER_REPOS="$saved_allow"

# Summary --------------------------------------------------------------------
echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
