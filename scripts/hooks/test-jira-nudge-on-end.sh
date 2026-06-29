#!/usr/bin/env bash
# Hermetic test for scripts/hooks/jira-nudge-on-end.sh (HIMMEL-618).
#
# Builds a throwaway git repo + transcript + breadcrumb under a redirected HOME
# and drives the SessionEnd hook across the detection matrix. Asserts the hook
# emits EXACTLY one nudge when (and only when) all gates pass, and NEVER invokes
# the jira CLI (a `node` tripwire stub on PATH must stay untouched).
#
# Usage: bash scripts/hooks/test-jira-nudge-on-end.sh
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOK_DIR/jira-nudge-on-end.sh"

FAILED=0
PASSED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "$ROOT_TMP"' EXIT

# PATH stub: a `node` that, if ever invoked, trips the wire. The hook must never
# shell the jira CLI.
STUB_DIR="$ROOT_TMP/stubs"
mkdir -p "$STUB_DIR"
TRIPWIRE="$ROOT_TMP/node-was-called"
cat > "$STUB_DIR/node" <<EOF
#!/usr/bin/env bash
echo called >> "$TRIPWIRE"
exit 0
EOF
chmod +x "$STUB_DIR/node"

# Relay stub: records each invocation so we can assert relay-once / relay-never.
RELAY_LOG="$ROOT_TMP/relay.log"
RELAY_CMD="$STUB_DIR/relay"
cat > "$RELAY_CMD" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$RELAY_LOG"
EOF
chmod +x "$RELAY_CMD"

# ---- case builder ----------------------------------------------------------
# Globals set by build_case: CASE_HOME, CASE_REPO, CASE_PAYLOAD
build_case() {
    # args: <first_ts> <branch> <commit_subject> <env_key:0|1> <breadcrumb:0|1> [commit_date]
    # commit_date (optional): GIT_*_DATE for the commit; defaults to "now".
    local first_ts="$1" branch="$2" subject="$3" with_key="$4" with_bc="$5" commit_date="${6:-}"
    CASE_HOME="$(mktemp -d "$ROOT_TMP/home.XXXXXX")"
    CASE_REPO="$(mktemp -d "$ROOT_TMP/repo.XXXXXX")"

    git -C "$CASE_REPO" init -q
    # Isolate from the operator's global git config: no inherited hooksPath
    # (a global pre-commit/commit-msg hook would fire — and possibly hang — on
    # these throwaway commits), no GPG signing prompt.
    git -C "$CASE_REPO" config core.hooksPath /dev/null
    git -C "$CASE_REPO" config commit.gpgsign false
    git -C "$CASE_REPO" config user.email t@t.t
    git -C "$CASE_REPO" config user.name tester
    git -C "$CASE_REPO" remote add origin https://github.com/acme/demo.git
    git -C "$CASE_REPO" checkout -q -b "$branch"
    echo x > "$CASE_REPO/f.txt"
    git -C "$CASE_REPO" add f.txt
    if [ -n "$commit_date" ]; then
        GIT_AUTHOR_DATE="$commit_date" GIT_COMMITTER_DATE="$commit_date" \
            git -C "$CASE_REPO" commit -q --no-verify -m "$subject"
    else
        git -C "$CASE_REPO" commit -q --no-verify -m "$subject"
    fi

    if [ "$with_key" = "1" ]; then
        printf 'JIRA_PROJECT_KEY=HIMMEL\n' > "$CASE_REPO/.env"
    fi

    # Transcript: a single JSONL line carrying .timestamp (or none for empty-FIRST_TS).
    local tx="$CASE_REPO/transcript.jsonl"
    if [ -n "$first_ts" ]; then
        printf '{"timestamp":"%s","role":"user","content":"hi"}\n' "$first_ts" > "$tx"
    else
        printf '{"role":"user","content":"hi"}\n' > "$tx"
    fi

    if [ "$with_bc" = "1" ]; then
        local bcdir="$CASE_HOME/.claude/jira-breadcrumbs"
        mkdir -p "$bcdir"
        # repo-key=demo, branch sanitized (/ -> -); epoch=now (>= any past start).
        local safe_branch
        safe_branch="$(printf '%s' "$branch" | sed 's/[^A-Za-z0-9._-]/-/g')"
        printf '%s\tHIMMEL-123\n' "$(date -u +%s)" > "$bcdir/demo__${safe_branch}.log"
    fi

    CASE_PAYLOAD="$(printf '{"transcript_path":"%s","cwd":"%s"}' "$tx" "$CASE_REPO")"
}

# ---- run helper ------------------------------------------------------------
# run_hook <gate> <initiative> → echoes stdout; sets RUN_RC
run_hook() {
    local gate="$1" initiative="$2"
    rm -f "$RELAY_LOG"
    local out
    out="$(printf '%s' "$CASE_PAYLOAD" | env -u JIRA_PROJECT_KEY \
        -u HIMMEL_INITIATIVE -u HIMMEL_INITIATIVE_OVERNIGHT -u HIMMEL_OVERNIGHT \
        HOME="$CASE_HOME" USERPROFILE="$CASE_HOME" PATH="$STUB_DIR:$PATH" \
        HIMMEL_JIRA_NUDGE="$gate" HIMMEL_INITIATIVE="$initiative" \
        JIRA_NUDGE_RELAY_CMD="$RELAY_CMD" \
        bash "$HOOK" 2>/dev/null)"
    printf '%s' "$out"
}

PAST="2020-01-01T00:00:00Z"

assert_nudge() {   # <label> <stdout>
    if printf '%s' "$2" | grep -q '\[jira-nudge\]'; then pass "$1"; else fail "$1 (expected nudge)"; fi
}
assert_no_nudge() {   # <label> <stdout>
    if printf '%s' "$2" | grep -q '\[jira-nudge\]'; then fail "$1 (unexpected nudge)"; else pass "$1"; fi
}

# 1. Happy path: gate on, commit in-window, ticket in branch, key set, no breadcrumb → NUDGE.
build_case "$PAST" "feat/HIMMEL-123" "did work" 1 0
OUT="$(run_hook 1 "")"
assert_nudge "happy-path nudges" "$OUT"
# exactly one nudge line
if [ "$(printf '%s\n' "$OUT" | grep -c '\[jira-nudge\]')" = "1" ]; then pass "exactly one nudge line"; else fail "exactly one nudge line"; fi
# relay invoked exactly once
if [ -f "$RELAY_LOG" ] && [ "$(grep -c . "$RELAY_LOG")" = "1" ]; then pass "relay invoked once"; else fail "relay invoked once"; fi

# 2. Gate OFF (default) → no nudge, no relay.
build_case "$PAST" "feat/HIMMEL-123" "did work" 1 0
OUT="$(run_hook 0 "")"
assert_no_nudge "gate-off suppresses" "$OUT"
if [ ! -f "$RELAY_LOG" ] || [ "$(grep -c . "$RELAY_LOG" 2>/dev/null || echo 0)" = "0" ]; then pass "relay not invoked (gate off)"; else fail "relay not invoked (gate off)"; fi

# 3. ticket leg active → suppress.
build_case "$PAST" "feat/HIMMEL-123" "did work" 1 0
OUT="$(run_hook 1 "ticket")"
assert_no_nudge "ticket-leg suppresses" "$OUT"

# 4. No commit in window (the only commit predates session start) → no nudge.
# Use real past dates (commit 2010, session start 2015) rather than a far-future
# sentinel: `git log --since=@<far-future-epoch>` is parsed inconsistently across
# git/platform builds, but a plain past `--since` excluding an older commit is
# uniform everywhere.
build_case "2015-01-01T00:00:00Z" "feat/HIMMEL-123" "did work" 1 0 "2010-01-01T00:00:00Z"
OUT="$(run_hook 1 "")"
assert_no_nudge "no-in-window-commit suppresses" "$OUT"

# 5. No ticket reference (branch + subject lack KEY-N) → no nudge.
build_case "$PAST" "feat/cleanup" "tidy things" 1 0
OUT="$(run_hook 1 "")"
assert_no_nudge "no-ticket-ref suppresses" "$OUT"

# 5b. Ticket only in the commit subject (not the branch) → NUDGE.
build_case "$PAST" "feat/cleanup" "HIMMEL-456 fix it" 1 0
OUT="$(run_hook 1 "")"
assert_nudge "ticket-in-commit nudges" "$OUT"

# 6. Breadcrumb present (mutation happened in window) → suppress.
build_case "$PAST" "feat/HIMMEL-123" "did work" 1 1
OUT="$(run_hook 1 "")"
assert_no_nudge "breadcrumb suppresses" "$OUT"

# 7. Empty FIRST_TS (transcript has no timestamp) → no nudge.
build_case "" "feat/HIMMEL-123" "did work" 1 0
OUT="$(run_hook 1 "")"
assert_no_nudge "empty-first-ts suppresses" "$OUT"

# 8. Unresolved KEY (no .env) → no nudge.
build_case "$PAST" "feat/HIMMEL-123" "did work" 0 0
OUT="$(run_hook 1 "")"
assert_no_nudge "unresolved-key suppresses" "$OUT"

# 8b. Relay is DETACHED + FIRED (HIMMEL-635): drive the real Telegram path (no
#     JIRA_NUDGE_RELAY_CMD seam) with a `curl` stub that DROPS A MARKER then
#     sleeps past the hook budget. The hook must return FAST (proving detach) AND
#     the marker must land (proving the relay was actually launched — the hook's
#     `trap exit 0` returns 0 on every path, so timing alone can't tell "detached"
#     from "never fired"). Skipped where GNU coreutils `timeout` is absent (stock
#     macOS); the detach primitive's setsid+disown branches are covered portably
#     by scripts/lib/test-detach.sh, so this case only proves the hook WIRES it.
if command -v timeout >/dev/null 2>&1; then
    build_case "$PAST" "feat/HIMMEL-123" "did work" 1 0
    CURL_MARK="$ROOT_TMP/curl-fired"
    rm -f "$CURL_MARK"
    # Unquoted heredoc so $CURL_MARK bakes into the stub; the surrounding quotes
    # stay literal (only $CURL_MARK expands).
    cat > "$STUB_DIR/curl" <<CURLEOF
#!/usr/bin/env bash
: > "$CURL_MARK"
sleep 12
CURLEOF
    chmod +x "$STUB_DIR/curl"
    _t0=$(date +%s)
    printf '%s' "$CASE_PAYLOAD" | timeout 15 env -u JIRA_PROJECT_KEY \
        -u HIMMEL_INITIATIVE -u HIMMEL_INITIATIVE_OVERNIGHT -u HIMMEL_OVERNIGHT \
        HOME="$CASE_HOME" USERPROFILE="$CASE_HOME" PATH="$STUB_DIR:$PATH" \
        HIMMEL_JIRA_NUDGE=1 TELEGRAM_BOT_TOKEN=t TELEGRAM_CHAT_ID=c \
        bash "$HOOK" >/dev/null 2>&1
    _rc=$?
    _elapsed=$(( $(date +%s) - _t0 ))
    # The detached curl writes its marker asynchronously — wait briefly for it.
    _w=0; while [ ! -f "$CURL_MARK" ] && [ "$_w" -lt 5 ]; do sleep 1; _w=$((_w + 1)); done
    rm -f "$STUB_DIR/curl"
    if [ "$_rc" -eq 0 ] && [ "$_elapsed" -lt 10 ] && [ -f "$CURL_MARK" ]; then
        pass "relay detached + fired (returns fast AND curl was launched)"
    else
        fail "relay detached + fired (rc=$_rc elapsed=${_elapsed}s marker=$([ -f "$CURL_MARK" ] && echo Y || echo N))"
    fi
    rm -f "$CURL_MARK"
else
    echo "SKIP relay-detached (no GNU coreutils timeout on this runner)"
fi

# 8c. Relay configured for NEITHER channel (no seam, no TELEGRAM_*) — the default
#     production posture. The hook must still emit the stdout nudge and exit 0.
build_case "$PAST" "feat/HIMMEL-123" "did work" 1 0
OUT="$(printf '%s' "$CASE_PAYLOAD" | env -u JIRA_PROJECT_KEY \
    -u HIMMEL_INITIATIVE -u HIMMEL_INITIATIVE_OVERNIGHT -u HIMMEL_OVERNIGHT \
    -u JIRA_NUDGE_RELAY_CMD -u TELEGRAM_BOT_TOKEN -u TELEGRAM_CHAT_ID \
    HOME="$CASE_HOME" USERPROFILE="$CASE_HOME" PATH="$STUB_DIR:$PATH" \
    HIMMEL_JIRA_NUDGE=1 bash "$HOOK" 2>/dev/null)"
assert_nudge "neither-channel still nudges stdout" "$OUT"

# 9. Tripwire: the jira CLI (node) was never invoked across all cases.
if [ -f "$TRIPWIRE" ]; then fail "jira CLI never invoked"; else pass "jira CLI never invoked"; fi

echo "---"
echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" -eq 0 ]
