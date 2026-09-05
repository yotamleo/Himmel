#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-pr-mergeable.sh (HIMMEL-136).
#
# Covers:
#   1. main branch -> exit 0 (no gate).
#   2. gh missing -> exit 0 (best-effort).
#   3. No PR -> exit 0.
#   4. PR MERGEABLE -> exit 0.
#   5. PR CONFLICTING -> exit 1 + helpful stderr.
#   6. SKIP_PR_MERGEABLE=1 short-circuits even on CONFLICTING.
#   7. Stdin drained (pipe with multi-line input does not deadlock).
#   8. CONFLICTING but provably STALE (base merged into local head, clean tree)
#      -> exit 0 (HIMMEL-1074 carve-out).
#   9. CONFLICTING + base NOT an ancestor of local head -> exit 1, message
#      names the sanctioned recovery.
#  10. CONFLICTING + base IS an ancestor BUT pushed tree carries conflict
#      markers -> exit 1 (the marker guard catches a botched resolution).
#  11. CONFLICTING + base IS an ancestor, tree has NO markers, but the
#      conflict-marker `git diff` itself FAILS -> exit 1 (a failed diff is
#      inconclusive evidence, not a clean tree — must not silently allow).
#  12. CONFLICTING + base WOULD be an ancestor but refreshing `origin/<base>`
#      (the pre-ancestor-check `git fetch`) FAILS -> exit 1 (a stale cached
#      remote-tracking ref is inconclusive evidence, not proof of staleness).
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/check-pr-mergeable.sh"

PASS=0; FAIL=0; TMP_ROOT=""
# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_contains() {
    local n="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F -- "$needle"; then pass "$n"; else fail "$n" "missing: $needle"; fi
}
assert_rc() {
    local n="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$n"; else fail "$n" "want=$want got=$got"; fi
}

TMP_ROOT=$(mktemp -d); if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

# Fake gh: behavior driven by FAKE_GH_* env.
#
# HIMMEL-1232: forge_pr_mergeable (github) now reads only base+head refs from gh
# and computes the conflict LOCALLY via `git merge-tree`. So the fake emits
# "<base> <headoid>" (a synchronous field read), and the test drives a clean vs
# conflicting verdict by pointing FAKE_GH_HEAD at a real clean / conflicting
# commit in the repo below — not by returning a mocked mergeable string.
FAKE_GH="$TMP_ROOT/gh-fake.sh"
cat >"$FAKE_GH" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
    "auth status")
        [ "${FAKE_GH_AUTH:-ok}" = "ok" ] && exit 0 || exit 1
        ;;
    "pr view")
        if [ "${FAKE_GH_NO_PR:-0}" = "1" ]; then
            # gh pr view exits non-zero with no stdout when no PR exists; the
            # forge backend's `|| return 0` turns that into an empty verdict.
            exit 1
        fi
        # Emit per the --json fields the caller asked for:
        #  - forge_pr_mergeable: `gh pr view <branch> --json
        #    baseRefName,headRefOid --jq ...` -> "<base> <headoid>".
        #  - check-pr-mergeable's staleness carve-out (HIMMEL-1074):
        #    `gh pr view <branch> --json baseRefName --jq ...` -> "<base>".
        for _f in "$@"; do
            case "$_f" in
                baseRefName,headRefOid)
                    printf '%s %s\n' "${FAKE_GH_BASE:-main}" "${FAKE_GH_HEAD:?FAKE_GH_HEAD unset}"
                    exit 0
                    ;;
            esac
        done
        printf '%s\n' "${FAKE_GH_BASE:-main}"
        exit 0
        ;;
esac
exit 0
FAKE
chmod +x "$FAKE_GH"

# tmp repo on a non-main branch, with real clean + conflicting branches so
# `git merge-tree` produces a genuine verdict.
REPO="$TMP_ROOT/repo"
git init -q --initial-branch=main "$REPO" 2>/dev/null || git init -q "$REPO"
(
    cd "$REPO" || exit 99
    git config user.email t@test.com; git config user.name test
    printf 'a\nb\nc\n' > f; git add f; git commit -q -m "init"
    git branch -m main 2>/dev/null || true
    # clean branch: adds an unrelated file — no overlap with main.
    git checkout -q -b feat/clean
    echo x > g; git add g; git commit -q -m clean
    # conflict branch off init changes line 2; main then changes the same line.
    git checkout -q -b feat/conflict main
    printf 'a\nTHEIRS\nc\n' > f; git add f; git commit -q -m theirs
    git checkout -q main
    printf 'a\nOURS\nc\n' > f; git add f; git commit -q -m ours
    # feat/test is the branch under test (the hook reads its NAME); its own
    # content is irrelevant — the fake injects the head commit to check.
    git checkout -q -b feat/test main
    # Forge seam (HIMMEL-326): the hook resolves the forge from origin; a github
    # origin selects the github backend (gh pr view via the GH_CMD stub).
    git remote add origin https://github.com/test/test.git
)
CLEAN_OID=$(git -C "$REPO" rev-parse feat/clean)
CONFLICT_OID=$(git -C "$REPO" rev-parse feat/conflict)

# Fake `git`: shadows PATH so the hook's `git fetch origin <base>` (HIMMEL-1074
# CR round — refreshes the cached origin/<base> ref before trusting it) never
# makes a real network call against the fake `origin` URL. Default behavior is
# a no-op success — the hermetic fixtures below pre-populate
# refs/remotes/origin/<base> directly via `git update-ref`, so no actual fetch
# is needed for the ref data to be correct. FAKE_GIT_FETCH_FAIL=1 simulates a
# failed fetch (offline / unreachable); FAKE_GIT_DIFF_FAIL=1 simulates the
# conflict-marker `git diff origin/<base>...HEAD` itself failing. Every other
# invocation (symbolic-ref, merge-base, rev-parse, checkout, ...) delegates to
# the real git untouched.
REAL_GIT=$(command -v git)
FAKE_GIT_BIN="$TMP_ROOT/fakegit"
mkdir -p "$FAKE_GIT_BIN"
cat >"$FAKE_GIT_BIN/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "fetch" ]; then
    [ "\${FAKE_GIT_FETCH_FAIL:-0}" = "1" ] && exit 1
    exit 0
fi
if [ "\$1" = "diff" ] && [[ "\$2" == *...* ]] && [ "\${FAKE_GIT_DIFF_FAIL:-0}" = "1" ]; then
    exit 1
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$FAKE_GIT_BIN/git"
# PATH needs the POSIX form (/tmp/... not C:/...) for bash's own lookup to
# find it — TMP_ROOT was cygpath -m'd to Windows form above for git-remote-url
# purposes elsewhere in this file, which breaks $PATH resolution under MSYS.
FAKE_GIT_BIN_POSIX="$FAKE_GIT_BIN"
if command -v cygpath >/dev/null 2>&1; then FAKE_GIT_BIN_POSIX=$(cygpath -u "$FAKE_GIT_BIN"); fi

# The forge github backend invokes "${GH_CMD}" by its absolute path (no PATH
# lookup, no word-split), so GH_CMD must be a single executable — point it at
# the +x fake directly (HIMMEL-326; was `bash $FAKE_GH` before the seam).
# shellcheck disable=SC2120
run() {
    (
        # shellcheck disable=SC2030,SC2031,SC2164
        cd "$REPO" || exit 99
        # shellcheck disable=SC2030,SC2031
        export GH_CMD="$FAKE_GH"
        # shellcheck disable=SC2030,SC2031
        export PATH="$FAKE_GIT_BIN_POSIX:$PATH"
        printf 'refs/heads/feat/test sha refs/heads/feat/test sha\n' | bash "$HOOK" "$@"
    )
}

# Test 1: main branch -> exit 0 ---------------------------------------
echo "TEST: main branch exits 0"
( cd "$REPO" || exit 99; git checkout -q main )
rc=0
out=$( cd "$REPO" || exit 99; printf '' | bash "$HOOK" 2>&1 ) || rc=$?
assert_rc "main rc=0" "0" "$rc"
( cd "$REPO" || exit 99; git checkout -q feat/test )

# Test 1b: master branch -> exit 0 (HIMMEL-297) -----------------------
echo "TEST: master branch exits 0 (HIMMEL-297 — master is a protected default too)"
( cd "$REPO" || exit 99; git checkout -q -b master )
rc=0
out=$( cd "$REPO" || exit 99; printf '' | bash "$HOOK" 2>&1 ) || rc=$?
assert_rc "master rc=0" "0" "$rc"
( cd "$REPO" || exit 99; git checkout -q feat/test; git branch -D master 2>/dev/null || true )

# Test 2: gh missing -> exit 0 ----------------------------------------
echo "TEST: gh missing -> best-effort exit 0"
rc=0
out=$(
    cd "$REPO" || exit 99
    # Set GH_CMD to a non-existent binary to simulate "gh missing".
    GH_CMD="/no/such/gh-binary" bash "$HOOK" </dev/null 2>&1
) || rc=$?
assert_rc "gh-missing rc=0" "0" "$rc"
assert_contains "stderr explains best-effort" "best-effort" "$out"

# Test 3: no PR -> exit 0 ---------------------------------------------
echo "TEST: no PR found -> exit 0"
rc=0
# shellcheck disable=SC2030,SC2031
out=$(export FAKE_GH_NO_PR=1; run 2>&1) || rc=$?
assert_rc "no-pr rc=0" "0" "$rc"

# Test 4: clean branch -> MERGEABLE -> exit 0 -------------------------
echo "TEST: clean branch (merge-tree MERGEABLE) -> exit 0"
rc=0
# shellcheck disable=SC2030,SC2031
out=$(export FAKE_GH_HEAD="$CLEAN_OID"; run 2>&1) || rc=$?
assert_rc "mergeable rc=0" "0" "$rc"

# Test 5: conflicting branch -> CONFLICTING -> exit 1 -----------------
echo "TEST: conflicting branch (merge-tree CONFLICTING) -> exit 1 + helpful stderr"
rc=0
# shellcheck disable=SC2030,SC2031
out=$(export FAKE_GH_HEAD="$CONFLICT_OID"; run 2>&1) || rc=$?
assert_rc "conflicting rc=1" "1" "$rc"
assert_contains "stderr mentions CONFLICTING" "CONFLICTING state" "$out"
assert_contains "stderr suggests inspect"     "gh pr view"        "$out"
assert_contains "stderr names bypass var"     "SKIP_PR_MERGEABLE"  "$out"

# Test 6: SKIP_PR_MERGEABLE=1 short-circuits --------------------------
echo "TEST: SKIP_PR_MERGEABLE=1 short-circuits even on a conflicting branch"
rc=0
# shellcheck disable=SC2030,SC2031
out=$(export SKIP_PR_MERGEABLE=1 FAKE_GH_HEAD="$CONFLICT_OID"; run 2>&1) || rc=$?
assert_rc "skip rc=0" "0" "$rc"
assert_contains "stderr explains skip" "SKIP_PR_MERGEABLE=1" "$out"

# Test 7: stdin drained -----------------------------------------------
echo "TEST: multi-line stdin drained without deadlock"
rc=0
out=$(
    # shellcheck disable=SC2030,SC2031,SC2164
    cd "$REPO" || exit 99
    # shellcheck disable=SC2030,SC2031
    export GH_CMD="$FAKE_GH" FAKE_GH_HEAD="$CLEAN_OID"
    printf 'a b c d\ne f g h\n' | bash "$HOOK" 2>&1
) || rc=$?
assert_rc "multi-line stdin rc=0" "0" "$rc"

# Test 8: stale CONFLICTING -> ALLOWED (HIMMEL-1074) -------------------
echo "TEST: stale CONFLICTING (base merged into local head, clean tree) -> exit 0"
# Build the resolved scenario: feat/test gains a clean commit on top of main,
# and a remote-tracking origin/main is materialized (no network) so the carve-out's
# `git merge-base --is-ancestor origin/<base> HEAD` resolves locally. The fake
# still reports the OLD conflicting remote head (feat/conflict), so the verdict is
# CONFLICTING by construction while the local head already contains the base.
(
    cd "$REPO" || exit 99
    git checkout -q feat/test
    printf 'resolved\n' > r; git add r; git commit -q -m resolved
    git update-ref refs/remotes/origin/main "$(git rev-parse main)"
)
rc=0
# shellcheck disable=SC2030,SC2031
out=$(export FAKE_GH_HEAD="$CONFLICT_OID"; run 2>&1) || rc=$?
assert_rc "stale-conflicting rc=0" "0" "$rc"
assert_contains "stderr explains stale allow" "provably stale" "$out"
# HIMMEL-2371: the deny message no longer carries the ticket ID inline (moved
# to the code comment above check-pr-mergeable.sh's own echo line) — assert
# the substance of the allow message instead of the now-stripped ticket ref.
assert_contains "stderr allows the push" "Allowing the push" "$out"
RESOLVED_OID=$(git -C "$REPO" rev-parse feat/test)

# Test 9: CONFLICTING + base NOT an ancestor -> REFUSED ----------------
echo "TEST: CONFLICTING with base NOT merged into local head -> exit 1 + recovery"
# feat/conflict is a sibling of main (branched from init, never merged 'ours' in),
# so origin/main is NOT an ancestor of it. The carve-out must REFUSE and name the
# sanctioned recovery. Assert on the MESSAGE, not just rc — rc alone cannot tell a
# helpful refusal from an unhelpful one.
(
    cd "$REPO" || exit 99
    git checkout -q feat/conflict
)
rc=0
# shellcheck disable=SC2030,SC2031
out=$(export FAKE_GH_HEAD="$CONFLICT_OID"; run 2>&1) || rc=$?
assert_rc "not-ancestor rc=1" "1" "$rc"
assert_contains "stderr names sanctioned recovery" "Sanctioned recovery"   "$out"
assert_contains "stderr shows merge command"        "git merge origin/main" "$out"
(
    cd "$REPO" || exit 99
    git checkout -q feat/test
)

# Test 10: CONFLICTING + base IS ancestor BUT tree has markers -> REFUSED
echo "TEST: stale-looking CONFLICTING but pushed tree carries conflict markers -> exit 1"
# feat/test has origin/main as an ancestor, but this commit introduces a real
# conflict-marker block — the guard must catch it and refuse. A genuinely
# conflicted tree is never waved through, even when the base is merged in.
(
    cd "$REPO" || exit 99
    git checkout -q feat/test
    printf '<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch\n' > mc.txt
    git add mc.txt; git commit -q -m markers
)
rc=0
# shellcheck disable=SC2030,SC2031
out=$(export FAKE_GH_HEAD="$CONFLICT_OID"; run 2>&1) || rc=$?
assert_rc "markers-present rc=1" "1" "$rc"
assert_contains "stderr names sanctioned recovery" "Sanctioned recovery" "$out"

# Test 11: CONFLICTING + ancestor merged + clean tree BUT the conflict-marker
# `git diff` itself fails -> REFUSED (HIMMEL-1074 CR round: a failed diff must
# not read as "no markers found" and silently allow) -------------------------
echo "TEST: stale-looking CONFLICTING but the conflict-marker git diff fails -> exit 1"
# Build on RESOLVED_OID (ancestor merged, no markers — would be ALLOWED if the
# diff succeeded). run()'s PATH shim fetches as a no-op (already set up) and
# FAKE_GIT_DIFF_FAIL=1 fails only the diff invocation.
(
    cd "$REPO" || exit 99
    git checkout -q -B feat/difffail "$RESOLVED_OID"
)
rc=0
# shellcheck disable=SC2030,SC2031
out=$(export FAKE_GH_HEAD="$CONFLICT_OID" FAKE_GIT_DIFF_FAIL=1; run 2>&1) || rc=$?
assert_rc "diff-fails rc=1" "1" "$rc"
assert_contains "stderr names sanctioned recovery" "Sanctioned recovery" "$out"

# Test 12: CONFLICTING + ancestor WOULD be merged but the pre-check `git
# fetch origin <base>` fails -> REFUSED (HIMMEL-1074 CR round: a stale cached
# origin/<base> is inconclusive evidence — a local ref that hasn't been
# refreshed could satisfy the ancestor check while the CURRENT remote base
# still genuinely conflicts) -------------------------------------------------
echo "TEST: stale-looking CONFLICTING but refreshing origin/<base> (git fetch) fails -> exit 1"
# Reuse the same resolved/ancestor-merged tree as test 11 (feat/difffail is
# still checked out) — it WOULD be allowed if the fetch succeeded, proving the
# fetch failure alone (not the diff/markers check) causes the refusal.
rc=0
# shellcheck disable=SC2030,SC2031
out=$(export FAKE_GH_HEAD="$CONFLICT_OID" FAKE_GIT_FETCH_FAIL=1; run 2>&1) || rc=$?
assert_rc "fetch-fails rc=1" "1" "$rc"
assert_contains "stderr names sanctioned recovery" "Sanctioned recovery" "$out"
(
    cd "$REPO" || exit 99
    git checkout -q feat/test
)

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
