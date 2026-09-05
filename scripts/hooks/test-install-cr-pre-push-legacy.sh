#!/usr/bin/env bash
# Contract test for scripts/hooks/install-cr-pre-push-legacy.sh (HIMMEL-1574,
# HIMMEL-2371).
#
# core.hooksPath points every worktree at the PRIMARY checkout's .git/hooks, so
# all worktrees execute the same pre-push.legacy file. That shim used to resolve
# the gate through `git rev-parse --show-toplevel`, which from a worktree is the
# WORKTREE root — so each worktree ran its own base commit's copy of
# scripts/hooks/check-cr-before-push.sh. Pre-push hardening therefore silently
# did not apply to worktrees created before it, and the stale gate reports
# success (fail-OPEN).
#
# The discriminating fixture: a primary checkout whose gate prints GATE-CURRENT
# and a worktree, based on an older commit, whose gate prints GATE-STALE. The
# shim must run the PRIMARY's copy no matter which worktree invoked it, and
# refuse (exit 2) rather than fall back to a worktree copy when the primary has
# no gate at all.
#
# HIMMEL-2371: the shim also runs scripts/hooks/check-push-target.sh — with the
# SAME captured ref stream — ahead of the CR gate, so the direct-push-to-main
# block sees git's complete, undrained ref stream (the pre-commit-configured
# shape alone only ever sees the FIRST pushed ref). A push-target fixture that
# prints PUSH-GATE-OK and forwards stdin, alongside the existing CR-gate
# fixture, proves both are wired; a push-target fixture that blocks (exit 1)
# proves the CR gate never runs afterward.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install-cr-pre-push-legacy.sh"
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/fixture-tempdir.sh"

# A runner that exports git's per-invocation env (pre-commit does) would make
# every `git` below resolve against THIS repository instead of the fixture.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX \
      GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CONFIG_PARAMETERS

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

command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

TMP_ROOT=$(fixture_mktemp_dir) || exit 1
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi

PRIMARY="$TMP_ROOT/primary"
WORKTREE="$TMP_ROOT/stale-worktree"
GATE_REL="scripts/hooks/check-cr-before-push.sh"
PUSH_GATE_REL="scripts/hooks/check-push-target.sh"
REF_LINE="refs/heads/feat/x aaaa refs/heads/feat/x 0000000000000000000000000000000000000000"

git init -q -b main "$PRIMARY" 2>/dev/null || { git init -q "$PRIMARY"; git -C "$PRIMARY" symbolic-ref HEAD refs/heads/main; }
git -C "$PRIMARY" config user.email t@test.com
git -C "$PRIMARY" config user.name test
mkdir -p "$PRIMARY/scripts/hooks"

# A non-blocking push-target fixture: prints a marker and FORWARDS stdin (to
# stdout, same as GATE-CURRENT below) rather than discarding it, so a test can
# assert the push-target gate actually received the ref stream too, not just
# that it ran.
printf '#!/usr/bin/env bash\necho "PUSH-GATE-OK"\ncat\n' > "$PRIMARY/$PUSH_GATE_REL"
git -C "$PRIMARY" add "$PUSH_GATE_REL"
git -C "$PRIMARY" commit -qm "push-target gate"

# Commit 1: the STALE gate the worktree will carry.
printf '#!/usr/bin/env bash\necho "GATE-STALE"\n' > "$PRIMARY/$GATE_REL"
git -C "$PRIMARY" add "$GATE_REL"
git -C "$PRIMARY" commit -qm "stale gate"
git -C "$PRIMARY" branch stale

# Commit 2: the CURRENT gate, echoing its argv and forwarding stdin so the test
# can prove the shim passes both through untouched.
printf '#!/usr/bin/env bash\necho "GATE-CURRENT args=$*"\ncat\n' > "$PRIMARY/$GATE_REL"
git -C "$PRIMARY" add "$GATE_REL"
git -C "$PRIMARY" commit -qm "current gate"

git -C "$PRIMARY" worktree add -q "$WORKTREE" stale 2>/dev/null || {
    echo "SKIP: git worktree add failed in the fixture"; exit 0
}

LEGACY="$PRIMARY/.git/hooks/pre-push.legacy"

echo "TEST: installer writes an executable, marker-carrying pre-push.legacy"
rc=0; out=$(cd "$PRIMARY" && bash "$INSTALLER" 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && [ -x "$LEGACY" ] && grep -Fq '# himmel-cr-ref-stream-v1' "$LEGACY"; then
    pass "installer exits 0 and installs an executable owner-marked hook"
else
    fail "installer did not install the hook (rc=$rc)" "out: $out"
fi

# run_legacy_from DIR [env-assignments...] — invoke the installed shim the way
# git does: cwd at a working tree, the ref stream on stdin.
run_legacy_from() {
    local dir="$1"; shift
    (
        cd "$dir" || exit 1
        printf '%s\n' "$REF_LINE" | env "$@" bash "$LEGACY" origin https://example.com/repo.git
    ) 2>&1
}

echo "TEST: invoked from the PRIMARY checkout -> runs the primary's gate"
out=$(run_legacy_from "$PRIMARY")
case "$out" in
    *"GATE-CURRENT"*) pass "primary invocation runs the current gate" ;;
    *) fail "primary invocation did not reach the current gate" "out: $out" ;;
esac
case "$out" in
    *"PUSH-GATE-OK"*) pass "primary invocation runs the push-target gate too (HIMMEL-2371)" ;;
    *) fail "primary invocation did not reach the push-target gate" "out: $out" ;;
esac
# Both gates forward the ref stream to stdout (see the fixtures above), so a
# COMPLETE, undrained stream reaching both — not just the CR gate — shows up
# as the ref line appearing exactly twice (codex-1: prove each gate actually
# received the stream, not just that it ran).
ref_line_count=$(printf '%s\n' "$out" | grep -Fc "$REF_LINE")
if [ "$ref_line_count" -eq 2 ]; then
    pass "the ref stream reaches BOTH the push-target gate and the CR gate"
else
    fail "expected the ref line twice (once per gate), saw $ref_line_count" "out: $out"
fi

echo "TEST: invoked from a worktree based on an OLDER commit -> still runs the PRIMARY's gate"
out=$(run_legacy_from "$WORKTREE")
case "$out" in
    *"GATE-STALE"*) fail "worktree invocation ran the worktree's stale gate (HIMMEL-1574)" "out: $out" ;;
    *"GATE-CURRENT"*) pass "worktree invocation runs the primary's current gate" ;;
    *) fail "worktree invocation reached no gate at all" "out: $out" ;;
esac
case "$out" in
    *"args=origin https://example.com/repo.git"*) pass "shim forwards git's argv to the gate" ;;
    *) fail "shim did not forward argv" "out: $out" ;;
esac
case "$out" in
    *"$REF_LINE"*) pass "shim forwards the raw ref stream on stdin" ;;
    *) fail "shim did not forward stdin" "out: $out" ;;
esac

echo "TEST: worktree invocation with GIT_DIR exported (git's real hook env) -> primary's gate"
out=$(run_legacy_from "$WORKTREE" "GIT_DIR=$PRIMARY/.git/worktrees/stale-worktree")
case "$out" in
    *"GATE-CURRENT"*) pass "GIT_DIR-scoped worktree invocation still runs the primary's gate" ;;
    *) fail "GIT_DIR-scoped worktree invocation did not reach the current gate" "out: $out" ;;
esac

echo "TEST: push-target gate BLOCKS (exit 1) -> shim refuses, CR gate never runs (HIMMEL-2371)"
printf '#!/usr/bin/env bash\necho "PUSH-GATE-BLOCKED"\ncat >/dev/null\nexit 1\n' > "$PRIMARY/$PUSH_GATE_REL"
rc=0; out=$(run_legacy_from "$PRIMARY") || rc=$?
if [ "$rc" -eq 1 ]; then
    pass "a blocking push-target gate makes the shim exit 1"
else
    fail "a blocking push-target gate should make the shim exit 1, got $rc" "out: $out"
fi
case "$out" in
    *"GATE-CURRENT"*) fail "CR gate ran even though the push-target gate blocked" "out: $out" ;;
    *"PUSH-GATE-BLOCKED"*) pass "the CR gate never runs once the push-target gate blocks" ;;
    *) fail "expected PUSH-GATE-BLOCKED output" "out: $out" ;;
esac
printf '#!/usr/bin/env bash\necho "PUSH-GATE-OK"\ncat >/dev/null\n' > "$PRIMARY/$PUSH_GATE_REL"

echo "TEST: primary has no push-target gate -> refuse (exit 2), never fall back or run the CR gate"
mv "$PRIMARY/$PUSH_GATE_REL" "$TMP_ROOT/push-gate.bak"
rc=0; out=$(run_legacy_from "$PRIMARY") || rc=$?
if [ "$rc" -eq 2 ]; then
    pass "missing push-target gate -> exit 2 (fail closed)"
else
    fail "missing push-target gate -> expected exit 2 got $rc" "out: $out"
fi
case "$out" in
    *"GATE-CURRENT"*) fail "CR gate ran even though the push-target gate is missing" "out: $out" ;;
    *"cannot locate scripts/hooks/check-push-target.sh"*) pass "refusal names the missing push-target gate" ;;
    *) fail "refusal message does not name the missing push-target gate" "out: $out" ;;
esac
mv "$TMP_ROOT/push-gate.bak" "$PRIMARY/$PUSH_GATE_REL"

echo "TEST: primary has no gate -> refuse (exit 2), never fall back to a worktree copy"
mv "$PRIMARY/$GATE_REL" "$TMP_ROOT/gate.bak"
rc=0; out=$(run_legacy_from "$WORKTREE") || rc=$?
if [ "$rc" -eq 2 ]; then
    pass "missing primary gate -> exit 2 (fail closed)"
else
    fail "missing primary gate -> expected exit 2 got $rc" "out: $out"
fi
case "$out" in
    *"GATE-STALE"*) fail "fell back to the worktree's stale gate instead of refusing" "out: $out" ;;
    *"cannot locate scripts/hooks/check-cr-before-push.sh"*) pass "refusal names the missing gate" ;;
    *) fail "refusal message does not name the missing gate" "out: $out" ;;
esac
mv "$TMP_ROOT/gate.bak" "$PRIMARY/$GATE_REL"

echo "TEST: installer overwrites its OWN older version in place"
# shellcheck disable=SC2016  # writing the OLD hook body verbatim; no expansion wanted
printf '#!/usr/bin/env bash\n# himmel-cr-ref-stream-v1\nrepo_root=$(git rev-parse --show-toplevel)\nexec bash "$repo_root/%s"\n' "$GATE_REL" > "$LEGACY"
rc=0; out=$(cd "$PRIMARY" && bash "$INSTALLER" 2>&1) || rc=$?
# shellcheck disable=SC2016  # matching that verbatim body, not expanding it
if [ "$rc" -eq 0 ] && grep -Fq 'git worktree list --porcelain' "$LEGACY" &&
   ! grep -Fq 'exec bash "$repo_root/' "$LEGACY"; then
    pass "an owner-marked older hook is replaced by the current one"
else
    fail "installer did not replace its own older hook (rc=$rc)" "out: $out"
fi

echo "TEST: installer refuses to overwrite a hook it does not own"
printf '#!/bin/sh\necho FOREIGN-HOOK\n' > "$LEGACY"
rc=0; out=$(cd "$PRIMARY" && bash "$INSTALLER" 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && grep -Fq 'FOREIGN-HOOK' "$LEGACY"; then
    pass "non-Himmel pre-push.legacy is left untouched (exit 2)"
else
    fail "installer must refuse a foreign hook (rc=$rc)" "out: $out"
fi

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
