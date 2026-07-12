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
# run_hook <gate> <initiative> → echoes stdout
# Drives the hook in CHILD MODE (`__himmel_detached <payload-file>`) — the
# production parent full-body-detaches (HIMMEL-661) and its stdout goes to
# /dev/null, so the detection matrix asserts on the child's direct stdout.
# The parent path itself is covered by the fast-return + relay cases below.
run_hook() {
    local gate="$1" initiative="$2"
    rm -f "$RELAY_LOG"
    local pf out
    pf="$(mktemp "$ROOT_TMP/payload.XXXXXX")"
    printf '%s' "$CASE_PAYLOAD" > "$pf"
    out="$(env -u JIRA_PROJECT_KEY \
        -u HIMMEL_INITIATIVE -u HIMMEL_INITIATIVE_OVERNIGHT -u HIMMEL_OVERNIGHT \
        HOME="$CASE_HOME" USERPROFILE="$CASE_HOME" PATH="$STUB_DIR:$PATH" \
        HIMMEL_JIRA_NUDGE="$gate" HIMMEL_INITIATIVE="$initiative" \
        JIRA_NUDGE_RELAY_CMD="$RELAY_CMD" \
        bash "$HOOK" __himmel_detached "$pf" 2>/dev/null)"
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

# 8b. PARENT MODE end-to-end (HIMMEL-635 + HIMMEL-661): drive the production
#     entry path (piped payload, no child-mode args) through the real Telegram
#     branch (no JIRA_NUDGE_RELAY_CMD seam) with a `curl` stub that DROPS A
#     MARKER then sleeps past the hook budget. The parent must return FAST
#     (proving the full-body detach) AND the marker must land (proving the
#     detached child ran the whole detection body and launched the relay — the
#     hook's `trap exit 0` returns 0 on every path, so timing alone can't tell
#     "detached" from "never fired"). Skipped where GNU coreutils `timeout` is
#     absent (stock macOS); the detach primitive's setsid+disown branches are
#     covered portably by scripts/lib/test-detach.sh.
if command -v timeout >/dev/null 2>&1; then
    build_case "$PAST" "feat/HIMMEL-123" "did work" 1 0
    CURL_MARK="$ROOT_TMP/curl-fired"
    CURL_ARGS="$ROOT_TMP/curl-args"
    rm -f "$CURL_MARK" "$CURL_ARGS"
    # Unquoted heredoc so $CURL_MARK/$CURL_ARGS bake into the stub; the
    # surrounding quotes stay literal. Args are recorded BEFORE the marker so
    # a present marker implies complete args.
    cat > "$STUB_DIR/curl" <<CURLEOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$CURL_ARGS"
: > "$CURL_MARK"
sleep 12
CURLEOF
    chmod +x "$STUB_DIR/curl"
    # Isolated TMPDIR so the parent's OWN mktemp'd payload file is observable:
    # after the relay fires, the dir must be empty again (child deleted it) —
    # the end-to-end proof of the production temp-file lifecycle.
    TMPDIR_8B="$ROOT_TMP/tmpdir-8b"
    mkdir -p "$TMPDIR_8B"
    _t0=$(date +%s)
    printf '%s' "$CASE_PAYLOAD" | timeout 15 env -u JIRA_PROJECT_KEY \
        -u HIMMEL_INITIATIVE -u HIMMEL_INITIATIVE_OVERNIGHT -u HIMMEL_OVERNIGHT \
        HOME="$CASE_HOME" USERPROFILE="$CASE_HOME" PATH="$STUB_DIR:$PATH" \
        TMPDIR="$TMPDIR_8B" \
        HIMMEL_JIRA_NUDGE=1 TELEGRAM_BOT_TOKEN=t TELEGRAM_CHAT_ID=c \
        bash "$HOOK" >/dev/null 2>&1
    _rc=$?
    _elapsed=$(( $(date +%s) - _t0 ))
    # The detached child runs the FULL detection chain before firing curl —
    # allow 10s (matches test-codex-stop-hooks.sh §3; 5s flaked risk on
    # loaded CI runners).
    _w=0; while [ ! -f "$CURL_MARK" ] && [ "$_w" -lt 10 ]; do sleep 1; _w=$((_w + 1)); done
    rm -f "$STUB_DIR/curl"
    if [ "$_rc" -eq 0 ] && [ "$_elapsed" -lt 10 ] && [ -f "$CURL_MARK" ]; then
        pass "relay detached + fired (returns fast AND curl was launched)"
    else
        fail "relay detached + fired (rc=$_rc elapsed=${_elapsed}s marker=$([ -f "$CURL_MARK" ] && echo Y || echo N))"
    fi
    # Payload integrity across the parent->temp-file->child roundtrip: the
    # relayed message must carry the detected ticket, not just fire at all.
    if grep -q 'HIMMEL-123' "$CURL_ARGS" 2>/dev/null; then
        pass "relayed message carries the ticket (payload survived the temp-file roundtrip)"
    else
        fail "relayed message carries the ticket (args: $(cat "$CURL_ARGS" 2>/dev/null))"
    fi
    # Production temp-file lifecycle: the parent's own mktemp'd payload file
    # must be gone once the child has fired the relay (child deletes it before
    # detection). A leak here means the parent->child handoff regressed.
    if [ -z "$(ls -A "$TMPDIR_8B" 2>/dev/null)" ]; then
        pass "parent's payload temp file cleaned up end-to-end"
    else
        fail "parent's payload temp file cleaned up end-to-end (left: $(ls -A "$TMPDIR_8B"))"
    fi
    rm -f "$CURL_MARK" "$CURL_ARGS"
else
    echo "SKIP relay-detached (no GNU coreutils timeout on this runner)"
fi

# 8c. Relay configured for NEITHER channel (no seam, no TELEGRAM_*) — the default
#     production posture. Child mode must still emit the stdout nudge (direct-
#     invocation contract), exit 0, and DELETE the payload temp file it was
#     handed (temp hygiene — the parent never cleans up after the child).
build_case "$PAST" "feat/HIMMEL-123" "did work" 1 0
PF_8C="$(mktemp "$ROOT_TMP/payload.XXXXXX")"
printf '%s' "$CASE_PAYLOAD" > "$PF_8C"
OUT="$(env -u JIRA_PROJECT_KEY \
    -u HIMMEL_INITIATIVE -u HIMMEL_INITIATIVE_OVERNIGHT -u HIMMEL_OVERNIGHT \
    -u JIRA_NUDGE_RELAY_CMD -u TELEGRAM_BOT_TOKEN -u TELEGRAM_CHAT_ID \
    HOME="$CASE_HOME" USERPROFILE="$CASE_HOME" PATH="$STUB_DIR:$PATH" \
    HIMMEL_JIRA_NUDGE=1 bash "$HOOK" __himmel_detached "$PF_8C" 2>/dev/null)"
assert_nudge "neither-channel still nudges stdout (child mode)" "$OUT"
if [ ! -f "$PF_8C" ]; then pass "child deletes its payload temp file"; else fail "child deletes its payload temp file"; fi

# 8d. Full-body detach keeps the PARENT fast (HIMMEL-661). The discriminating
#     test: inject latency at the START of the child body (JIRA_NUDGE_TEST_DELAY)
#     — BEFORE the gate check — so a regression that un-detaches the body would
#     block the parent for 12s and fail the fast-return assertion. Gate is OFF
#     here on purpose: even the gate-off path must not run in the foreground.
#     Skipped where GNU coreutils `timeout` is absent (stock macOS).
if command -v timeout >/dev/null 2>&1; then
    build_case "$PAST" "feat/HIMMEL-123" "did work" 1 0
    _t0=$(date +%s)
    printf '%s' "$CASE_PAYLOAD" | timeout 15 env -u JIRA_PROJECT_KEY \
        -u HIMMEL_INITIATIVE -u HIMMEL_INITIATIVE_OVERNIGHT -u HIMMEL_OVERNIGHT \
        HOME="$CASE_HOME" USERPROFILE="$CASE_HOME" PATH="$STUB_DIR:$PATH" \
        HIMMEL_JIRA_NUDGE=0 JIRA_NUDGE_TEST_DELAY=12 \
        bash "$HOOK" >/dev/null 2>&1
    _rc=$?
    _elapsed=$(( $(date +%s) - _t0 ))
    if [ "$_rc" -eq 0 ] && [ "$_elapsed" -lt 10 ]; then
        pass "full-body detach: parent returns fast despite slow child (${_elapsed}s)"
    else
        fail "full-body detach: parent returns fast despite slow child (rc=$_rc elapsed=${_elapsed}s)"
    fi
else
    echo "SKIP parent-fast (no GNU coreutils timeout on this runner)"
fi

# 8e. Parent with EMPTY stdin exits 0 and spawns NOTHING — the no-payload guard
#     keeps a payload-less teardown spawn-free. TMPDIR is pointed at an empty
#     dir and JIRA_NUDGE_TEST_DELAY holds any (wrongly) spawned child asleep
#     BEFORE it can read+delete its payload file, so a regression of the
#     `[ -n "$PAYLOAD" ]` guard leaves the parked temp file visible here.
build_case "$PAST" "feat/HIMMEL-123" "did work" 1 0
EMPTY_TMPDIR="$ROOT_TMP/empty-tmpdir"
mkdir -p "$EMPTY_TMPDIR"
printf '' | env -u JIRA_PROJECT_KEY \
    -u HIMMEL_INITIATIVE -u HIMMEL_INITIATIVE_OVERNIGHT -u HIMMEL_OVERNIGHT \
    HOME="$CASE_HOME" USERPROFILE="$CASE_HOME" PATH="$STUB_DIR:$PATH" \
    TMPDIR="$EMPTY_TMPDIR" HIMMEL_JIRA_NUDGE=1 JIRA_NUDGE_TEST_DELAY=12 \
    JIRA_NUDGE_RELAY_CMD="$RELAY_CMD" \
    bash "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then pass "empty-payload parent exits 0"; else fail "empty-payload parent exits 0 (rc=$rc)"; fi
if [ -z "$(ls -A "$EMPTY_TMPDIR" 2>/dev/null)" ]; then
    pass "empty-payload parent parks no temp file (no child spawned)"
else
    fail "empty-payload parent parks no temp file (found: $(ls -A "$EMPTY_TMPDIR"))"
fi

# 9. Tripwire: the jira CLI (node) was never invoked across all cases.
if [ -f "$TRIPWIRE" ]; then fail "jira CLI never invoked"; else pass "jira CLI never invoked"; fi

echo "---"
echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" -eq 0 ]
