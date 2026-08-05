#!/usr/bin/env bash
# Integration test for scripts/hooks/check-cr-before-push.sh THROUGH the real
# pre-commit pre-push shim (HIMMEL-1540, CR rounds 2-3).
#
# The 34 cases in test-check-cr-before-push.sh invoke the script directly (a
# here-string on stdin), which BYPASSES the pre-commit framework. In production
# this hook is installed via pre-commit: .git/hooks/pre-push is a pre-commit-
# generated shim that consumes git's stdin itself (hook_impl._run_legacy does
# sys.stdin.buffer.read()) and surfaces the pushed ref to hooks ONLY through
# PRE_COMMIT_* env vars — so the script's stdin loop is unreachable and, before
# HIMMEL-1540, the marker fell back to the worktree's checked-out branch,
# leaving the actually-pushed destination ungated (Direction A: fail-OPEN).
#
# This test generates the REAL shim in a temp repo, feeds it a ref line naming a
# destination branch that is NOT the worktree's checked-out branch, and asserts
# the marker is written for the DESTINATION branch (and certifies the pushed
# SHA, not the worktree HEAD). This is the test gap that hid the defect for a
# full CR round.
#
# Skips cleanly (exit 0) where pre-commit is not installed, so the suite stays
# runnable on boxes that install hooks another way.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/check-cr-before-push.sh"
INSTALLER="$SCRIPT_DIR/install-cr-pre-push-legacy.sh"
LIB="$SCRIPT_DIR/../guardrails/lib.sh"

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
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

command -v pre-commit >/dev/null 2>&1 || { echo "SKIP: pre-commit not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$(mktemp -d)"); else TMP_ROOT=$(mktemp -d); fi
ZERO=0000000000000000000000000000000000000000

# marker_path REPO BRANCH — absolute path to the branch's cr-pending marker.
marker_path() {
    local repo="$1" branch="$2" git_dir
    git_dir=$(git -C "$repo" rev-parse --git-common-dir)
    case "$git_dir" in /*|?:/*|?:\\*) ;; *) git_dir="$repo/$git_dir" ;; esac
    echo "${git_dir}/cr-pending/${branch}"
}

# build_repo [with-origin] — temp repo with the hook + lib + a one-hook
# pre-commit config. Leaves `feat/worktree-branch` (with a code commit) checked
# out, plus a separate `feat/destination-branch` at the same SHA (so the
# identity gate passes: the local destination exists at the pushed SHA). Sets
# globals REPO, dest_sha, SHIM. With `with-origin`, configures a real origin
# remote holding main, so pre-commit resolves PRE_COMMIT_TO_REF (the common
# production path); without it, the push hits pre-commit's "whole tree" case and
# only PRE_COMMIT_LOCAL_BRANCH is set — exercising the SHA-recovery fallback.
build_repo() {
    local with_origin="${1:-}"
    REPO="$TMP_ROOT/repo"
    rm -rf "$REPO" "$TMP_ROOT/origin.git"
    git init -q -b main "$REPO"
    git -C "$REPO" config user.email t@t.t
    git -C "$REPO" config user.name t
    # The operator box sets core.hooksPath globally; a fresh temp repo inherits
    # it and pre-commit then refuses to install. A LOCAL empty override masks
    # the global value (git config --get then returns "") so pre-commit's
    # has_core_hookpaths_set() check passes — without touching the operator's
    # global config.
    git -C "$REPO" config --local core.hooksPath ""
    git -C "$REPO" commit -q --allow-empty -m init
    mkdir -p "$REPO/scripts/hooks" "$REPO/scripts/guardrails"
    cp "$HOOK" "$REPO/scripts/hooks/check-cr-before-push.sh"
    cp "$INSTALLER" "$REPO/scripts/hooks/install-cr-pre-push-legacy.sh"
    cp "$LIB" "$REPO/scripts/guardrails/lib.sh"
    cat > "$REPO/.pre-commit-config.yaml" <<'YAML'
repos:
  - repo: local
    hooks:
      - id: code-review-before-push
        name: CR marker
        language: system
        entry: bash scripts/hooks/check-cr-before-push.sh
        pass_filenames: false
        always_run: true
        stages: [pre-push]
YAML
    if [ "$with_origin" = "with-origin" ]; then
        git clone -q --bare "$REPO" "$TMP_ROOT/origin.git"
        git -C "$REPO" remote add origin "$TMP_ROOT/origin.git"
        git -C "$REPO" fetch -q origin
    fi
    # worktree branch (checked out) with code — the buggy fallback would mark THIS.
    git -C "$REPO" checkout -q -b feat/worktree-branch
    echo 'function f() {}' > "$REPO/code.sh"
    git -C "$REPO" add code.sh
    git -C "$REPO" commit -qm "code on worktree branch"
    dest_sha=$(git -C "$REPO" rev-parse HEAD)
    # DIFFERENT destination branch at the same SHA (identity gate passes).
    git -C "$REPO" checkout -q main
    git -C "$REPO" branch feat/destination-branch "$dest_sha"
    git -C "$REPO" checkout -q feat/worktree-branch
    (cd "$REPO" && pre-commit install --hook-type pre-push >/dev/null 2>&1)
    (cd "$REPO" && bash scripts/hooks/install-cr-pre-push-legacy.sh >/dev/null 2>&1)
    SHIM="$REPO/.git/hooks/pre-push"
}

# feed_shim REFLINE — pipe one ref line into the real generated pre-push shim.
feed_shim() {
    printf '%s\n' "$1" | (cd "$REPO" && bash "$SHIM" origin https://example.com/repo.git) 2>&1
}

# assert_destination_marked NAME — the discriminating assertion: a push whose
# destination is NOT the worktree's checked-out branch writes a marker FOR the
# destination branch (certifying the pushed SHA), and NOT for the worktree HEAD.
assert_destination_marked() {
    local name="$1"
    local m_dest m_wt marker_sha marker_remote marker_remote_ref
    local marker_endpoint marker_base main_sha
    m_dest=$(marker_path "$REPO" feat/destination-branch)
    m_wt=$(marker_path "$REPO" feat/worktree-branch)
    if [ -f "$m_dest" ]; then
        pass "$name: destination-branch marker written through the real pre-push shim"
    else
        fail "$name: destination-branch marker missing — the pre-commit stdin-consume defect is not fixed"
    fi
    if [ ! -f "$m_wt" ]; then
        pass "$name: worktree-branch marker NOT written (ref stream honored, not the fallback)"
    else
        fail "$name: worktree-branch marker written — legacy fallback ran (the bug)"
    fi
    if [ -f "$m_dest" ]; then
        marker_sha=$(awk -F' [|] ' '{print $2; exit}' "$m_dest" 2>/dev/null || true)
        marker_remote=$(awk -F' [|] ' '{print $4; exit}' "$m_dest" 2>/dev/null || true)
        marker_remote_ref=$(awk -F' [|] ' '{print $5; exit}' "$m_dest" 2>/dev/null || true)
        if [ "$marker_sha" = "$dest_sha" ] && [ "$marker_remote" = "origin" ] &&
           [ "$marker_remote_ref" = "refs/heads/feat/destination-branch" ]; then
            pass "$name: destination marker certifies pushed SHA + remote ref"
        else
            fail "$name: destination marker binding '$marker_sha' '$marker_remote' '$marker_remote_ref' is wrong"
        fi
        # HIMMEL-1540 R5: the marker must also pin the push endpoint E (the URL
        # the shim passed) and the immutable diff-base SHA B (the repo's main).
        marker_endpoint=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6; exit}' "$m_dest" 2>/dev/null || true)
        marker_base=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$7); print $7; exit}' "$m_dest" 2>/dev/null || true)
        main_sha=$(git -C "$REPO" rev-parse --verify refs/heads/main 2>/dev/null || true)
        if [ "$marker_endpoint" = "https://example.com/repo.git" ] && [ "$marker_base" = "$main_sha" ]; then
            pass "$name: destination marker pins endpoint E + immutable base B"
        else
            fail "$name: marker endpoint/base '$marker_endpoint' '$marker_base' (want https://example.com/repo.git / $main_sha)"
        fi
    fi
}

# ── Scenario 1: with origin → PRE_COMMIT_TO_REF set (common production path) ─
echo "TEST: real shim (origin present) — destination != worktree writes DESTINATION marker"
build_repo with-origin
[ -f "$SHIM" ] || fail "scenario 1: pre-commit did not install a pre-push shim"
if ! feed_shim "refs/heads/feat/destination-branch $dest_sha refs/heads/feat/destination-branch $ZERO" >/dev/null 2>&1; then
    fail "real generated shim refused the single-ref push"
fi
assert_destination_marked "scenario-1-origin"

# ── Scenario 2: no origin → PRE_COMMIT_TO_REF unset, LOCAL_BRANCH fallback ───
# Exercises the SHA-recovery branch: pre-commit's "push the whole tree" case
# omits TO_REF, so the hook must resolve PRE_COMMIT_LOCAL_BRANCH to the SHA.
echo "TEST: real shim (no origin) — destination marker via LOCAL_BRANCH SHA fallback"
build_repo
[ -f "$SHIM" ] || fail "scenario 2: pre-commit did not install a pre-push shim"
if ! feed_shim "refs/heads/feat/destination-branch $dest_sha refs/heads/feat/destination-branch $ZERO" >/dev/null 2>&1; then
    fail "real generated shim refused the single-ref push"
fi
assert_destination_marked "scenario-2-no-origin"

# ── Scenario 3: real multi-ref stream reaches pre-push.legacy in full ─────────
echo "TEST: real shim — two pushed refs both receive destination markers"
build_repo with-origin
legacy="$REPO/.git/hooks/pre-push.legacy"
(cd "$REPO" && pre-commit install --hook-type pre-push >/dev/null 2>&1)
if [ -x "$legacy" ] && grep -Fq '# himmel-cr-ref-stream-v1' "$legacy"; then
    pass "scenario-3-multi: repeated pre-commit install preserves Himmel legacy hook"
else
    fail "scenario-3-multi: repeated pre-commit install dropped the Himmel legacy hook"
fi
git -C "$REPO" checkout -q main
git -C "$REPO" checkout -q -b feat/source-two
printf 'function g() {}\n' > "$REPO/code-two.sh"
git -C "$REPO" add code-two.sh
git -C "$REPO" commit -qm "second pushed ref"
second_sha=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" branch feat/destination-two "$second_sha"
git -C "$REPO" checkout -q feat/worktree-branch
multi_refs="refs/heads/feat/destination-branch $dest_sha refs/heads/feat/destination-branch $ZERO
refs/heads/feat/source-two $second_sha refs/heads/feat/destination-two $ZERO"
rc=0
out=$(feed_shim "$multi_refs") || rc=$?
if [ "$rc" -eq 0 ]; then
    pass "scenario-3-multi: real generated shim accepts two-ref push"
else
    fail "scenario-3-multi: real generated shim returned $rc ($out)"
fi
m_first=$(marker_path "$REPO" feat/destination-branch)
m_second=$(marker_path "$REPO" feat/destination-two)
if [ -f "$m_first" ] && [ -f "$m_second" ]; then
    pass "scenario-3-multi: both destination markers were written"
else
    fail "scenario-3-multi: one or both destination markers are missing"
fi
if [ "$(awk -F' [|] ' '{print $2; exit}' "$m_first" 2>/dev/null || true)" = "$dest_sha" ] &&
   [ "$(awk -F' [|] ' '{print $2; exit}' "$m_second" 2>/dev/null || true)" = "$second_sha" ]; then
    pass "scenario-3-multi: both markers certify their own pushed SHA"
else
    fail "scenario-3-multi: marker SHAs do not match both pushed refs"
fi

# ── Scenario 4: missing legacy hook — refuse ONCE for the TRUE reason, bind ──
# the first-ref marker via PRE_COMMIT_REMOTE_NAME, self-heal, retry passes.
# Leg-44 regression guard: the configured-hook shape carries the remote name in
# env, not argv; reading only argv produced a false "no remote identity"
# refusal on every framework-shaped push. rc alone is NOT enough — the old
# assertion passed on the wrong refusal.
echo "TEST: real shim — missing Himmel legacy hook: true refusal + bound marker + self-heal retry"
build_repo with-origin
rm -f "$REPO/.git/hooks/pre-push.legacy"
rc=0
out=$(feed_shim "refs/heads/feat/destination-branch $dest_sha refs/heads/feat/destination-branch $ZERO") || rc=$?
if [ "$rc" -ne 0 ]; then
    pass "scenario-4-no-legacy: generated shim refuses an uncertifiable ref stream"
else
    fail "scenario-4-no-legacy: generated shim exited 0 with only a partial PRE_COMMIT ref view ($out)"
fi
case "$out" in
    *"no remote identity"*)
        fail "scenario-4-no-legacy: false 'no remote identity' refusal — PRE_COMMIT_REMOTE_NAME transport regressed (leg-44)" ;;
    *)
        pass "scenario-4-no-legacy: refusal is not the false 'no remote identity' premise" ;;
esac
case "$out" in
    *"only the first pushed ref"*)
        pass "scenario-4-no-legacy: refusal states the true reason (partial PRE_COMMIT view)" ;;
    *)
        fail "scenario-4-no-legacy: refusal lacks the actionable partial-view message ($out)" ;;
esac
m_dest=$(marker_path "$REPO" feat/destination-branch)
if [ -f "$m_dest" ] &&
   [ "$(awk -F' [|] ' '{print $2; exit}' "$m_dest" 2>/dev/null || true)" = "$dest_sha" ] &&
   [ "$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4; exit}' "$m_dest" 2>/dev/null || true)" = "origin" ] &&
   [ "$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5; exit}' "$m_dest" 2>/dev/null || true)" = "refs/heads/feat/destination-branch" ] &&
   [ "$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6; exit}' "$m_dest" 2>/dev/null || true)" = "https://example.com/repo.git" ]; then
    pass "scenario-4-no-legacy: first-ref marker written with env-transported remote + endpoint binding"
else
    fail "scenario-4-no-legacy: first-ref marker missing or unbound (remote identity/endpoint not wired from PRE_COMMIT_REMOTE_NAME/URL)"
fi
legacy="$REPO/.git/hooks/pre-push.legacy"
if [ -x "$legacy" ] && grep -Fq '# himmel-cr-ref-stream-v1' "$legacy"; then
    pass "scenario-4-no-legacy: refusal self-healed by installing the Himmel legacy hook"
else
    fail "scenario-4-no-legacy: legacy hook not self-installed — every later push stays refused"
fi
rc=0
out=$(feed_shim "refs/heads/feat/destination-branch $dest_sha refs/heads/feat/destination-branch $ZERO") || rc=$?
if [ "$rc" -eq 0 ]; then
    pass "scenario-4-no-legacy: RETRY passes through the real shim (refuse-once converges)"
else
    fail "scenario-4-no-legacy: retry still refused ($rc: $out)"
fi

echo
echo "===================================="
echo "pre-commit integration summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
