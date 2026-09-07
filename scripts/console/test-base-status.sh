#!/usr/bin/env bash
# Unit test for scripts/console/base-status.sh (HIMMEL-2383). Exit 0 if all
# pass. GH_CMD stub seam (matches test-sweep-cr-threads.sh); no network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_STATUS="$SCRIPT_DIR/base-status.sh"

_fail=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s: %s\n' "$1" "$2"; _fail=$((_fail+1)); }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/base-status.XXXXXX") || { echo "cannot create temporary directory" >&2; exit 1; }
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT") || { echo "cannot convert temporary-directory path" >&2; exit 1; }
fi
# shellcheck disable=SC2329,SC2317  # invoked via the EXIT trap
cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null || true; }
trap cleanup EXIT

# Red-first fixture: PR 101 = PENDING (no SUMMARY comment at all), PR 102 =
# RED (a SUMMARY comment with FAIL: 2), PR 103 = clean (SUMMARY, FAIL: 0,
# must NOT appear in output), PR 104 = merged but does not touch the fence
# (must NOT appear in output even though it has no SUMMARY comment).
GH_STUB1="$TMP_ROOT/gh-stub-mixed.sh"
cat > "$GH_STUB1" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*)
        cat <<'JSON'
[
  {"number":101,"headRefOid":"aaa101","files":[{"path":"scripts/hooks/foo.sh"}]},
  {"number":102,"headRefOid":"aaa102","files":[{"path":"scripts/hooks/bar.sh"}]},
  {"number":103,"headRefOid":"aaa103","files":[{"path":"scripts/hooks/baz.sh"}]},
  {"number":104,"headRefOid":"aaa104","files":[{"path":"docs/unrelated.md"}]}
]
JSON
        ;;
    *"pr view 101"*"comments"*)
        echo '{"comments":[{"body":"@coderabbitai review"},{"body":"Rate limited by coderabbit.ai"}]}' ;;
    *"pr view 102"*"comments"*)
        echo '{"comments":[{"body":"== Summary ==\n head: aaa102\n scope: scripts/hooks\n PASS: 5\n SKIP: 0\n FAIL: 2\n"}]}' ;;
    *"pr view 103"*"comments"*)
        echo '{"comments":[{"body":"== Summary ==\n head: aaa103\n scope: scripts/hooks\n PASS: 7\n SKIP: 0\n FAIL: 0\n"}]}' ;;
    *"pr view 104"*"comments"*)
        echo "stub: PR 104 should never be queried — it does not touch the fence" >&2; exit 97 ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB1"

echo "TEST: mixed fixture — 101 PENDING, 102 RED, 103 clean+silent, 104 excluded"
out=$(GH_CMD="$GH_STUB1" "$BASE_STATUS" scripts/hooks 2>"$TMP_ROOT/err1")
rc=$?
m_pending=$(printf '%s\n' "$out" | grep -F "PENDING PR 101 fence=scripts/hooks head=aaa101")
m_red=$(printf '%s\n' "$out" | grep -F "RED PR 102 fence=scripts/hooks head=aaa102 FAIL=2")
m_103=$(printf '%s\n' "$out" | grep -F "103")
m_104=$(printf '%s\n' "$out" | grep -F "104")
if [ "$rc" -eq 0 ] && [ -n "$m_pending" ] && [ -n "$m_red" ] && [ -z "$m_103" ] && [ -z "$m_104" ]; then
    pass "mixed fixture classifies correctly"
else
    fail "mixed fixture" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err1")'"
fi

# A PR whose comments include unrelated prose ("80/80 pass") must still read
# as PENDING — the literal '== Summary ==' + 'PASS:' block is what counts,
# not any mention of test results (this is the exact #2092 shape found live).
GH_STUB2="$TMP_ROOT/gh-stub-prose.sh"
cat > "$GH_STUB2" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*)
        echo '[{"number":201,"headRefOid":"bbb201","files":[{"path":"scripts/hooks/foo.sh"}]}]' ;;
    *"pr view 201"*"comments"*)
        echo '{"comments":[{"body":"Only the scoped suite was run for this PR. Result: 80/80 pass."}]}' ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB2"

echo "TEST: prose test-result mention is still PENDING (not the literal block)"
out=$(GH_CMD="$GH_STUB2" "$BASE_STATUS" scripts/hooks 2>"$TMP_ROOT/err2")
rc=$?
m201=$(printf '%s\n' "$out" | grep -F "PENDING PR 201")
if [ "$rc" -eq 0 ] && [ -n "$m201" ]; then
    pass "prose note reads as PENDING"
else
    fail "prose note" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err2")'"
fi

# A comments-query failure on one PR is a QUERY-ERROR + nonzero exit, not a
# swallowed clean result (HIMMEL-2320 posture, matching sweep-cr-threads.sh).
GH_STUB3="$TMP_ROOT/gh-stub-commentfail.sh"
cat > "$GH_STUB3" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*)
        echo '[{"number":301,"headRefOid":"ccc301","files":[{"path":"scripts/hooks/foo.sh"}]}]' ;;
    *"pr view 301"*"comments"*) echo "gh: connection failed" >&2; exit 1 ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB3"

echo "TEST: a comments-query failure is QUERY-ERROR + nonzero exit"
out=$(GH_CMD="$GH_STUB3" "$BASE_STATUS" scripts/hooks 2>"$TMP_ROOT/err3")
rc=$?
err=$(cat "$TMP_ROOT/err3")
m_qerr=$(printf '%s\n' "$err" | grep -F "QUERY-ERROR PR 301")
if [ "$rc" -ne 0 ] && [ -n "$m_qerr" ]; then
    pass "comments-query failure -> QUERY-ERROR + nonzero exit"
else
    fail "comments-query failure" "rc=$rc out='$out' err='$err'"
fi

# Multiple fence args OR together; an exact-file fence matches only that file.
GH_STUB4="$TMP_ROOT/gh-stub-multifence.sh"
cat > "$GH_STUB4" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*)
        cat <<'JSON'
[
  {"number":401,"headRefOid":"ddd401","files":[{"path":"scripts/ci/run-shell-tests.sh"}]},
  {"number":402,"headRefOid":"ddd402","files":[{"path":"scripts/ci/other-file.sh"}]}
]
JSON
        ;;
    *"pr view 401"*"comments"*) echo '{"comments":[]}' ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB4"

echo "TEST: an exact-file fence matches only that file, not its siblings"
out=$(GH_CMD="$GH_STUB4" "$BASE_STATUS" scripts/ci/run-shell-tests.sh 2>"$TMP_ROOT/err4")
rc=$?
m401=$(printf '%s\n' "$out" | grep -F "PENDING PR 401")
m402=$(printf '%s\n' "$out" | grep -F "402")
if [ "$rc" -eq 0 ] && [ -n "$m401" ] && [ -z "$m402" ]; then
    pass "exact-file fence excludes siblings"
else
    fail "exact-file fence" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err4")'"
fi

# HIMMEL-2383 CR finding codex-3: a SUMMARY comment posted against an
# EARLIER revision of the PR (a stale head) must not certify the
# subsequently-merged head — PR 501's current headRefOid is "new501" but
# its only SUMMARY comment carries "head: old501".
GH_STUB5="$TMP_ROOT/gh-stub-stalehead.sh"
cat > "$GH_STUB5" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*)
        echo '[{"number":501,"headRefOid":"new501","files":[{"path":"scripts/hooks/foo.sh"}]}]' ;;
    *"pr view 501"*"comments"*)
        echo '{"comments":[{"body":"== Summary ==\n head: old501\n PASS: 9\n SKIP: 0\n FAIL: 0\n"}]}' ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB5"

echo "TEST: a SUMMARY at a stale (non-current) head reads PENDING, not clean"
out=$(GH_CMD="$GH_STUB5" "$BASE_STATUS" scripts/hooks 2>"$TMP_ROOT/err6")
rc=$?
m501=$(printf '%s\n' "$out" | grep -F "PENDING PR 501")
if [ "$rc" -eq 0 ] && [ -n "$m501" ]; then
    pass "stale-head SUMMARY reads PENDING"
else
    fail "stale-head SUMMARY" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err6")'"
fi

# HIMMEL-2383 CR finding codex-4: a TRUNCATED (budget-expired) report is
# PENDING regardless of its FAIL count — PR 502 has FAIL: 0 but is marked
# TRUNCATED, so it must not read as clean.
GH_STUB6="$TMP_ROOT/gh-stub-truncated.sh"
cat > "$GH_STUB6" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*)
        echo '[{"number":502,"headRefOid":"eee502","files":[{"path":"scripts/hooks/foo.sh"}]}]' ;;
    *"pr view 502"*"comments"*)
        echo '{"comments":[{"body":"== Summary ==\n head: eee502\n PASS: 5\n SKIP: 0\n FAIL: 0\n TRUNCATED: yes (run budget expired)\n"}]}' ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB6"

echo "TEST: a TRUNCATED report reads PENDING even with FAIL: 0"
out=$(GH_CMD="$GH_STUB6" "$BASE_STATUS" scripts/hooks 2>"$TMP_ROOT/err7")
rc=$?
m502=$(printf '%s\n' "$out" | grep -F "PENDING PR 502")
if [ "$rc" -eq 0 ] && [ -n "$m502" ]; then
    pass "TRUNCATED report reads PENDING despite FAIL: 0"
else
    fail "TRUNCATED report" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err7")'"
fi

# HIMMEL-2383 CR finding codex-5: an unparseable FAIL count must not default
# to clean — PR 503's SUMMARY carries the markers + a matching head, but no
# 'FAIL: <n>' line at all (a malformed/hand-copied report).
GH_STUB7="$TMP_ROOT/gh-stub-nofailcount.sh"
cat > "$GH_STUB7" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*)
        echo '[{"number":503,"headRefOid":"fff503","files":[{"path":"scripts/hooks/foo.sh"}]}]' ;;
    *"pr view 503"*"comments"*)
        echo '{"comments":[{"body":"== Summary ==\n head: fff503\n scope: scripts/hooks\n PASS: 5\n SKIP: 0\n"}]}' ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB7"

echo "TEST: a SUMMARY with no parseable FAIL count reads PENDING, not clean"
out=$(GH_CMD="$GH_STUB7" "$BASE_STATUS" scripts/hooks 2>"$TMP_ROOT/err8")
rc=$?
m503=$(printf '%s\n' "$out" | grep -F "PENDING PR 503")
if [ "$rc" -eq 0 ] && [ -n "$m503" ]; then
    pass "unparseable FAIL count reads PENDING"
else
    fail "unparseable FAIL count" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err8")'"
fi

# HIMMEL-2383 CR finding codex-2: hitting the merged-PR list limit means
# older history was not checked — that is a QUERY-ERROR (nonzero exit), not
# a silently-clean sweep. Generate exactly PR_LIST_LIMIT (200) merged PRs
# via jq rather than hand-writing them.
GH_STUB8="$TMP_ROOT/gh-stub-truncatedlist.sh"
PR_LIST_JSON8=$(jq -nc '[range(1;201) | {number:., headRefOid:"zzz", files:[{path:"docs/unrelated.md"}]}]')
cat > "$GH_STUB8" <<STUB
#!/usr/bin/env bash
case "\$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*) echo '$PR_LIST_JSON8' ;;
    *) echo "stub: unhandled gh args: \$*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB8"

echo "TEST: a merged-PR list AT the limit is a QUERY-ERROR (cannot certify complete)"
out=$(GH_CMD="$GH_STUB8" "$BASE_STATUS" scripts/hooks 2>"$TMP_ROOT/err9")
rc=$?
err=$(cat "$TMP_ROOT/err9")
m_limit=$(printf '%s\n' "$err" | grep -F "QUERY-ERROR: merged-PR list hit the 200-result limit")
if [ "$rc" -ne 0 ] && [ -n "$m_limit" ]; then
    pass "list truncated at the limit -> QUERY-ERROR + nonzero exit"
else
    fail "list truncated at the limit" "rc=$rc out='$out' err='$err'"
fi

# HIMMEL-2383 CR finding codex-3 (round 3): author-binding was tried in
# round 2 and REVERTED — this repo's multi-session, multi-machine
# architecture means the poster and the checker need not share a gh
# identity, so binding to "whoever gh is currently authenticated as" would
# silently and permanently reject legitimate reports posted under a
# different account. PR 601's SUMMARY carries the right head + markers but
# a DIFFERENT comment author than whatever this run happens to be
# authenticated as — it must still read clean; only the head-SHA binding
# (proven above) gates the result, never the author field.
GH_STUB9="$TMP_ROOT/gh-stub-anyauthor.sh"
cat > "$GH_STUB9" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*)
        echo '[{"number":601,"headRefOid":"ggg601","files":[{"path":"scripts/hooks/foo.sh"}]}]' ;;
    *"pr view 601"*"comments"*)
        echo '{"comments":[{"author":{"login":"some-other-account"},"body":"== Summary ==\n head: ggg601\n scope: scripts/hooks\n PASS: 9\n FAIL: 0\n"}]}' ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB9"

echo "TEST: a SUMMARY from a different comment author still reads clean (not author-bound)"
out=$(GH_CMD="$GH_STUB9" "$BASE_STATUS" scripts/hooks 2>"$TMP_ROOT/err10")
rc=$?
m601=$(printf '%s\n' "$out" | grep -F "601")
if [ "$rc" -eq 0 ] && [ -z "$m601" ]; then
    pass "different-author SUMMARY still reads clean"
else
    fail "different-author SUMMARY" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err10")'"
fi

# HIMMEL-2383 CR finding codex-4 (round 2): malformed JSON on a successful
# `gh pr list` exit must be a QUERY-ERROR, not a silent "0 PRs, all clean".
GH_STUB11="$TMP_ROOT/gh-stub-malformed.sh"
cat > "$GH_STUB11" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*) echo "not valid json" ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB11"

echo "TEST: malformed pr-list JSON on a successful exit is a QUERY-ERROR, not a clean 0"
rc=0
out=$(GH_CMD="$GH_STUB11" "$BASE_STATUS" scripts/hooks 2>"$TMP_ROOT/err12") || rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "malformed pr-list JSON aborts fail-closed"
else
    fail "malformed pr-list JSON" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err12")'"
fi

# HIMMEL-2383 CR finding codex-3 (round 5): malformed COMMENTS JSON on a
# successful `gh pr view` exit must be a QUERY-ERROR, not silently folded
# into the same PENDING outcome an empty/no-match comments list gets.
GH_STUB12="$TMP_ROOT/gh-stub-malformed-comments.sh"
cat > "$GH_STUB12" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*)
        echo '[{"number":701,"headRefOid":"jjj701","files":[{"path":"scripts/hooks/foo.sh"}]}]' ;;
    *"pr view 701"*"comments"*) echo "not valid json" ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB12"

echo "TEST: malformed comments JSON on a successful exit is a QUERY-ERROR, not PENDING"
out=$(GH_CMD="$GH_STUB12" "$BASE_STATUS" scripts/hooks 2>"$TMP_ROOT/err13")
rc=$?
err=$(cat "$TMP_ROOT/err13")
m_qerr=$(printf '%s\n' "$err" | grep -F "QUERY-ERROR PR 701")
m_pending=$(printf '%s\n' "$out" | grep -F "PENDING PR 701")
if [ "$rc" -ne 0 ] && [ -n "$m_qerr" ] && [ -z "$m_pending" ]; then
    pass "malformed comments JSON is a QUERY-ERROR, not PENDING"
else
    fail "malformed comments JSON" "rc=$rc out='$out' err='$err'"
fi

# HIMMEL-2383 CR finding codex-3 (round 6): valid-but-wrong-shaped JSON
# ({} or null, not an array) on a successful gh exit must be a QUERY-ERROR,
# not read as "0 PRs" (a jq `length` on either also returns a valid 0).
GH_STUB13="$TMP_ROOT/gh-stub-wrongshape.sh"
cat > "$GH_STUB13" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*) echo "{}" ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB13"

echo "TEST: a wrong-shaped ({}) pr-list JSON is a QUERY-ERROR, not a clean 0"
rc=0
out=$(GH_CMD="$GH_STUB13" "$BASE_STATUS" scripts/hooks 2>"$TMP_ROOT/err14") || rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "wrong-shaped pr-list JSON aborts fail-closed"
else
    fail "wrong-shaped pr-list JSON" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err14")'"
fi

# HIMMEL-2383 CR finding codex-4 (round 6): a fence arg WITH a trailing
# slash must still match — a natural way to spell a directory.
GH_STUB14="$TMP_ROOT/gh-stub-trailingslash.sh"
cat > "$GH_STUB14" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*)
        echo '[{"number":801,"headRefOid":"kkk801","files":[{"path":"scripts/hooks/foo.sh"}]}]' ;;
    *"pr view 801"*"comments"*) echo '{"comments":[]}' ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB14"

echo "TEST: a fence arg with a trailing slash still matches"
out=$(GH_CMD="$GH_STUB14" "$BASE_STATUS" scripts/hooks/ 2>"$TMP_ROOT/err15")
rc=$?
m801=$(printf '%s\n' "$out" | grep -F "PENDING PR 801")
if [ "$rc" -eq 0 ] && [ -n "$m801" ]; then
    pass "trailing-slash fence arg matches"
else
    fail "trailing-slash fence arg" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err15")'"
fi

# HIMMEL-2383 CR finding codex-1 (round 12): a SUMMARY with no scope line at
# all (an older-format report) must read PENDING, not clean — missing scope
# means "coverage unknown", not "assume covered".
GH_STUB15="$TMP_ROOT/gh-stub-noscope.sh"
cat > "$GH_STUB15" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*)
        echo '[{"number":504,"headRefOid":"lll504","files":[{"path":"scripts/hooks/foo.sh"}]}]' ;;
    *"pr view 504"*"comments"*)
        echo '{"comments":[{"body":"== Summary ==\n head: lll504\n PASS: 5\n SKIP: 0\n FAIL: 0\n"}]}' ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB15"

echo "TEST: a SUMMARY with no scope line reads PENDING, not clean"
out=$(GH_CMD="$GH_STUB15" "$BASE_STATUS" scripts/hooks 2>"$TMP_ROOT/err16")
rc=$?
m504=$(printf '%s\n' "$out" | grep -F "PENDING PR 504")
if [ "$rc" -eq 0 ] && [ -n "$m504" ]; then
    pass "missing scope line reads PENDING"
else
    fail "missing scope line" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err16")'"
fi

# HIMMEL-2383 CR finding codex-1 (round 12): a SUMMARY whose scope is a
# DIFFERENT, non-ancestor subtree (scripts/ci) must not certify an unrelated
# fence (scripts/hooks) as clean, even though PASS/head/markers all match.
GH_STUB16="$TMP_ROOT/gh-stub-scopemismatch.sh"
cat > "$GH_STUB16" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*)
        echo '[{"number":505,"headRefOid":"mmm505","files":[{"path":"scripts/hooks/foo.sh"}]}]' ;;
    *"pr view 505"*"comments"*)
        echo '{"comments":[{"body":"== Summary ==\n head: mmm505\n scope: scripts/ci\n PASS: 5\n SKIP: 0\n FAIL: 0\n"}]}' ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB16"

echo "TEST: a SUMMARY scoped to an unrelated subtree does not certify this fence"
out=$(GH_CMD="$GH_STUB16" "$BASE_STATUS" scripts/hooks 2>"$TMP_ROOT/err17")
rc=$?
m505=$(printf '%s\n' "$out" | grep -F "PENDING PR 505")
if [ "$rc" -eq 0 ] && [ -n "$m505" ]; then
    pass "unrelated scope does not certify this fence"
else
    fail "unrelated scope" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err17")'"
fi

# A SUMMARY scoped to an ANCESTOR of the fence (a full-tree "scripts" run)
# DOES certify it — scope need not equal the fence exactly.
GH_STUB17="$TMP_ROOT/gh-stub-scopeancestor.sh"
cat > "$GH_STUB17" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*)
        echo '[{"number":506,"headRefOid":"nnn506","files":[{"path":"scripts/hooks/foo.sh"}]}]' ;;
    *"pr view 506"*"comments"*)
        echo '{"comments":[{"body":"== Summary ==\n head: nnn506\n scope: scripts\n PASS: 5\n SKIP: 0\n FAIL: 0\n"}]}' ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB17"

echo "TEST: a SUMMARY scoped to an ancestor of the fence still certifies it"
out=$(GH_CMD="$GH_STUB17" "$BASE_STATUS" scripts/hooks 2>"$TMP_ROOT/err18")
rc=$?
m506=$(printf '%s\n' "$out" | grep -F "506")
if [ "$rc" -eq 0 ] && [ -z "$m506" ]; then
    pass "ancestor scope certifies the fence"
else
    fail "ancestor scope" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err18")'"
fi

# HIMMEL-2383 CR finding codex-1 (round 13): a PR touching TWO of the
# requested fences, with a report scoped to only ONE of them, must certify
# the covered fence but still flag the other as PENDING — not silently skip
# it because the first-matched fence happened to be clean.
GH_STUB18="$TMP_ROOT/gh-stub-multifence-partial.sh"
cat > "$GH_STUB18" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*)
        echo '[{"number":507,"headRefOid":"ooo507","files":[{"path":"scripts/hooks/foo.sh"},{"path":"scripts/console/bar.sh"}]}]' ;;
    *"pr view 507"*"comments"*)
        echo '{"comments":[{"body":"== Summary ==\n head: ooo507\n scope: scripts/hooks\n PASS: 5\n SKIP: 0\n FAIL: 0\n"}]}' ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB18"

echo "TEST: a PR touching two fences with a report scoped to only one flags the other PENDING"
out=$(GH_CMD="$GH_STUB18" "$BASE_STATUS" scripts/hooks scripts/console 2>"$TMP_ROOT/err19")
rc=$?
m_covered=$(printf '%s\n' "$out" | grep -F "fence=scripts/hooks")
m_uncovered=$(printf '%s\n' "$out" | grep -F "PENDING PR 507 fence=scripts/console")
if [ "$rc" -eq 0 ] && [ -z "$m_covered" ] && [ -n "$m_uncovered" ]; then
    pass "second touched fence is flagged PENDING even though the first is covered"
else
    fail "multi-fence partial coverage" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err19")'"
fi

# HIMMEL-2383 CR finding codex-2 (round 13): a --changed-since run's
# CHANGED-SINCE marker means suites were conditionally filtered — not full
# scope coverage — so it reads PENDING despite an otherwise-clean summary.
GH_STUB19="$TMP_ROOT/gh-stub-changedsince.sh"
cat > "$GH_STUB19" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*)
        echo '[{"number":508,"headRefOid":"ppp508","files":[{"path":"scripts/hooks/foo.sh"}]}]' ;;
    *"pr view 508"*"comments"*)
        echo '{"comments":[{"body":"== Summary ==\n head: ppp508\n scope: scripts\n PASS: 5\n SKIP: 0\n FAIL: 0\n CHANGED-SINCE: origin/main (suites were conditionally filtered — not full scope coverage)\n"}]}' ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB19"

echo "TEST: a CHANGED-SINCE report reads PENDING despite FAIL: 0"
out=$(GH_CMD="$GH_STUB19" "$BASE_STATUS" scripts/hooks 2>"$TMP_ROOT/err20")
rc=$?
m508=$(printf '%s\n' "$out" | grep -F "PENDING PR 508")
if [ "$rc" -eq 0 ] && [ -n "$m508" ]; then
    pass "CHANGED-SINCE report reads PENDING despite FAIL: 0"
else
    fail "CHANGED-SINCE report" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err20")'"
fi

echo "TEST: no fence args -> usage error"
rc=0
out=$(GH_CMD="$GH_STUB1" "$BASE_STATUS" 2>"$TMP_ROOT/err5") || rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "no args -> usage error"
else
    fail "no args" "rc=$rc out='$out'"
fi

if [ "$_fail" -eq 0 ]; then echo "OK"; exit 0; else echo "FAIL: $_fail"; exit 1; fi
