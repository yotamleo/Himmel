#!/usr/bin/env bash
# Smoke test for scripts/hooks/trigger-cr-on-pr-create.sh (HIMMEL-1362).
#
# HIMMEL-1362: a PostToolUse hook guarantees that a successful `gh pr create`
# is always followed by an `@coderabbitai review` comment, because CodeRabbit's
# auto_review is OFF on this repo and triggering had been left to agent
# discretion. This test exercises the hook with a STUBBED `gh` on PATH (no
# network): the stub returns canned existing comments for `gh api …/comments`
# and records `gh pr comment` calls to a log the assertions read.
#
# Covers (acceptance):
#   1. happy path: gh pr create + a PR URL in tool_response -> POSTS the trigger.
#   2. no PR URL in the response (failed / already-exists / dry-run) -> no post.
#   3. unrelated command (no `gh pr create`) -> fast-path exit, no post.
#   4. idempotency: a `@coderabbitai review` comment already exists -> no post.
#   4b. idempotency: a `@coderabbitai full review` comment already exists -> no post.
#   5. anchoring: `echo "gh pr create …"` (string literal) -> no post.
#   6. post-failure: the comment post fails -> hook stays non-blocking (rc 0).
#   7. subshell anchoring: `$(gh pr create …)` -> POSTS (command-position match).
#   8. multi-line command, INDENTED `gh pr create` line -> POSTS.
#   9. jq absent -> no post + a manual-trigger warning (never guess a PR URL
#      from tool_input).
set -euo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/trigger-cr-on-pr-create.sh"

# This SUITE requires jq: run_hook builds every payload with `jq -n --arg` so
# the command/stdout strings are properly JSON-escaped (see run_hook). The
# HOOK degrades gracefully without jq — test 9 exercises exactly that path —
# but the harness does not. Skip up front with a clear message instead of
# dying mid-suite on an obscure `jq: command not found`.
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

# NOTE: deliberately NOT cygpath-converting TMP_ROOT. This test puts a stubbed
# `gh` on PATH, and Git Bash does not search a mixed `C:/…` PATH entry — a
# cygpath'd dir would let the real `gh` win and the post would (correctly)
# fail. The native mktemp path (`/tmp/…` on Git Bash, already-native on
# macOS/Linux) is what PATH lookup needs, and we never hand these paths to a
# Windows-native tool here.
TMP_ROOT=$(mktemp -d)

# ─── stubbed gh (no network) ────────────────────────────────────────────────
# Dispatches on the subcommand the hook issues:
#   gh api repos/<o>/<r>/issues/<n>/comments   -> dump $FAKE_GH_COMMENTS_FILE
#   gh pr comment <n> --repo <o>/<r> --body X  -> append X to $FAKE_GH_COMMENT_LOG
#                                                  (exit 1 if FAKE_GH_COMMENT_FAIL=1)
GHSTUB_DIR="$TMP_ROOT/ghbin"
mkdir -p "$GHSTUB_DIR"
cat > "$GHSTUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
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
export FAKE_GH_COMMENT_LOG="$COMMENT_LOG"
export FAKE_GH_COMMENTS_FILE="$COMMENTS_FILE"

# Per-test reset: empty the posted-comment log, clear existing comments, clear
# the fail flag.
reset_state() {
    : > "$COMMENT_LOG"
    : > "$COMMENTS_FILE"
    export FAKE_GH_COMMENT_FAIL=0
}

# Run the hook with a given command string + tool_response.stdout, capturing its
# exit code in the global `rc`.
run_hook() {
    local command_str="$1"
    local response_stdout="$2"
    local payload
    # Build the payload with jq so the command/stdout strings are properly JSON
    # ESCAPED (CR codex-1). A printf-interpolated payload emits raw `"` from a
    # quoted command — e.g. `echo "gh pr create docs"` — producing MALFORMED
    # JSON. The hook then fails to parse it and exits early, so the anchoring
    # cases passed without ever reaching the anchoring regex: a vacuous test
    # that looked like the right negative case. Escaping makes these payloads
    # match what Claude Code actually sends.
    payload=$(jq -nc \
        --arg cmd "$command_str" \
        --arg out "$response_stdout" \
        '{tool_name:"Bash",tool_input:{command:$cmd},tool_response:{stdout:$out,stderr:""}}')
    rc=0
    out=$(printf '%s' "$payload" | bash "$HOOK" 2>&1) || rc=$?
}

# Count of trigger comments the hook caused the stub to record.
posted_count() { wc -l < "$COMMENT_LOG" 2>/dev/null | tr -d ' ' || echo 0; }

# Test 1: happy path — gh pr create + URL -> POSTS ---------------------------
echo "TEST: gh pr create with a PR URL in tool_response -> POSTS @coderabbitai review"
reset_state
run_hook "gh pr create --base main --title t --body b" "https://github.com/acme/widget/pull/1461"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 1 ]; then
    if grep -q '@coderabbitai review' "$COMMENT_LOG"; then
        pass "posted exactly one @coderabbitai review on PR #1461"
    else
        fail "posted, but body was not '@coderabbitai review'" "$(cat "$COMMENT_LOG")"
    fi
else
    fail "expected rc=0 and 1 posted comment, got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 2: no PR URL in response (failed / already-exists) -> no post ----------
echo "TEST: gh pr create with NO PR URL in tool_response -> no post"
reset_state
run_hook "gh pr create --base main" "pull request create failed: a pull request for branch feat/x already exists"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 0 ]; then
    pass "posted nothing when no PR URL is present"
else
    fail "expected rc=0 and 0 posts, got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 3: unrelated command -> no post ---------------------------------------
echo "TEST: unrelated command -> fast-path exit, no post"
reset_state
run_hook "git status" "https://github.com/acme/widget/pull/99"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 0 ]; then
    pass "posted nothing for a non-gh-pr-create command"
else
    fail "expected rc=0 and 0 posts, got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 4: idempotency — @coderabbitai review already exists -> no post --------
echo "TEST: existing @coderabbitai review comment -> no double-post"
reset_state
printf '@coderabbitai review\n' > "$COMMENTS_FILE"
run_hook "gh pr create --base main" "https://github.com/acme/widget/pull/42"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 0 ]; then
    pass "did not double-post when a review trigger already exists"
else
    fail "expected rc=0 and 0 posts, got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 4b: idempotency — @coderabbitai full review already exists -> no post --
echo "TEST: existing @coderabbitai full review comment -> no double-post"
reset_state
printf '@coderabbitai full review\n' > "$COMMENTS_FILE"
run_hook "gh pr create --base main" "https://github.com/acme/widget/pull/43"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 0 ]; then
    pass "did not double-post when a 'full review' trigger already exists"
else
    fail "expected rc=0 and 0 posts, got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 5: anchoring — echo string literal -> no post -------------------------
echo "TEST: echo \"gh pr create …\" (string literal, not command position) -> no post"
reset_state
run_hook 'echo "gh pr create docs"' "https://github.com/acme/widget/pull/7"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 0 ]; then
    pass "did not post for a gh-pr-create string inside echo"
else
    fail "expected rc=0 and 0 posts, got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 6: post-failure stays non-blocking ------------------------------------
echo "TEST: comment post fails -> hook stays non-blocking (rc 0), records warning"
reset_state
export FAKE_GH_COMMENT_FAIL=1
run_hook "gh pr create --base main" "https://github.com/acme/widget/pull/55"
if [ "$rc" -eq 0 ]; then
    if [ "$(posted_count)" -eq 0 ]; then
        pass "post-failure is non-blocking (rc 0) and records nothing"
    else
        fail "rc 0 but a comment was recorded despite the simulated failure" "$(cat "$COMMENT_LOG")"
    fi
else
    fail "expected rc=0 (non-blocking) on post failure, got rc=$rc" "out: $out"
fi
export FAKE_GH_COMMENT_FAIL=0

# Test 7: subshell anchoring — $(gh pr create …) -> POSTS --------------------
echo "TEST: \$(gh pr create …) (command substitution) -> POSTS"
reset_state
# shellcheck disable=SC2016  # single quotes are intentional: pass the LITERAL '$(gh pr create …)' string, not its expansion
run_hook '$(gh pr create -t foo)' "https://github.com/acme/widget/pull/9"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 1 ]; then
    pass "posted the trigger for gh pr create inside command substitution"
else
    fail "expected rc=0 and 1 post, got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 8: multi-line command, indented gh pr create line -> POSTS ------------
echo "TEST: multi-line command with an INDENTED gh pr create line -> POSTS"
reset_state
# Ordinary harness shape: a `&& \` continuation with the gh line indented.
# grep anchors `^` per line, so an unindented second line already matched; the
# indented form is the silent false negative glm-3 (round 2) flagged.
run_hook 'git add . && \
  gh pr create --title x' "https://github.com/acme/widget/pull/12"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 1 ]; then
    pass "posted for an indented gh pr create line in a multi-line command"
else
    fail "expected rc=0 and 1 post, got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 9: jq absent -> warns + does NOT post ---------------------------------
# A URL embedded in tool_input must never be mistaken for the new PR: the
# pre-fix text-only fallback scanned the WHOLE payload and would post the
# trigger on the wrong PR (#999 below). The fixed hook refuses to guess: it
# warns and exits 0.
echo "TEST: jq absent -> no post, warns (never guess a PR URL from tool_input)"
reset_state
NOJQ_BIN="$TMP_ROOT/nojqbin"
mkdir -p "$NOJQ_BIN"
REAL_BASH=$(command -v bash)
# Minimal PATH that hides jq but keeps what the hook (and the gh stub, should
# a regression let the hook reach it) needs. Wrapper scripts, not symlinks —
# Git Bash "symlinks" are file copies, and a copied bash.exe loses its DLLs.
for tool in bash cat grep head tail sed; do
    real=$(command -v "$tool")
    printf '#!%s\nexec %s "$@"\n' "$REAL_BASH" "$real" > "$NOJQ_BIN/$tool"
    chmod +x "$NOJQ_BIN/$tool"
done
# Payload built WITH jq (this suite has it — see the prerequisite guard): the
# command embeds a PR URL, the response carries none.
nojq_payload=$(jq -nc \
    --arg cmd 'gh pr create --title "closes https://github.com/acme/widget/pull/999"' \
    '{tool_name:"Bash",tool_input:{command:$cmd},tool_response:{stdout:"",stderr:""}}')
rc=0
out=$(printf '%s' "$nojq_payload" | env PATH="$NOJQ_BIN:$GHSTUB_DIR" "$REAL_BASH" "$HOOK" 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 0 ] && grepq "$out" 'jq not in PATH'; then
    pass "no-jq run posted nothing and warned about the missing jq"
else
    fail "expected rc=0, 0 posts, and a 'jq not in PATH' warning; got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 10: extra whitespace between argv words -> still POSTS ----------------
# `gh  pr create` is a perfectly valid invocation. The fast-path literal used
# to be `gh pr create`, so this exited BEFORE the anchored regex ran and the
# trigger was silently skipped (CR codex-1). Guards the looser literal.
echo "TEST: 'gh  pr create' (extra whitespace) -> POSTS"
reset_state
run_hook "gh  pr create --base main" "https://github.com/acme/widget/pull/77"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 1 ]; then
    pass "posted despite extra whitespace between argv words"
else
    fail "expected rc=0 and 1 post for 'gh  pr create', got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Test 11: whitespace in the OTHER gap -> still POSTS -------------------------
# `gh pr  create` broke the `pr create` literal the way `gh  pr create` broke
# `gh pr create` — one gap over. The fast path now matches the single token
# `create`, so no whitespace arrangement can produce a false negative.
echo "TEST: 'gh pr  create' (whitespace in the other gap) -> POSTS"
reset_state
run_hook "gh pr  create --base main" "https://github.com/acme/widget/pull/78"
if [ "$rc" -eq 0 ] && [ "$(posted_count)" -eq 1 ]; then
    pass "posted with whitespace between 'pr' and 'create'"
else
    fail "expected rc=0 and 1 post for 'gh pr  create', got rc=$rc posted=$(posted_count)" "out: $out"
fi

# Summary --------------------------------------------------------------------
echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
