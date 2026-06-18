#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-edit-on-main.sh.
#
# Usage: bash scripts/hooks/test-block-edit-on-main.sh
#
# The hook resolves the repo from the EDITED FILE's path (Himmel#45) by walking
# the file's own ancestors for a `.git`, NOT from CLAUDE_PROJECT_DIR. So the
# cases below build real throwaway repos under a sandbox and assert the hook
# reads the FILE's repo branch (not the launch dir's). Because repo_real is a
# literal prefix of the canonicalised file path, no GIT_CEILING/cygpath
# normalisation is needed (the resolution never calls `git -C <dir>
# --show-toplevel`, so there is no path-form mismatch to bridge). The only
# environmental assumption is that the runner's TMPDIR is not itself inside a
# git repo — asserted with a WARN at setup.
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/block-edit-on-main.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

FAILED=0

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

SANDBOX=$(mktemp -d)
# Two unbounded upward walks resolve the repo + read its branch: the hook's own
# `.git`-ancestor walk, and is_on_main → `git rev-parse` inside it. Both are
# correct for production (find the file's nearest enclosing repo) but mean the
# cases that depend on "this file is NOT inside any readable repo" — T4 (outside
# any repo → allow), T13 (traversal out → allow), and T14 (broken HEAD →
# fail-closed; its git walk-up would otherwise escape to an enclosing repo and
# read a real branch) — only hold when no ancestor of SANDBOX is itself a git
# repo. True on every real runner (TMPDIR = /tmp, /var/folders,
# AppData\Local\Temp). If not (a pathological TMPDIR inside a checkout), SKIP
# those three rather than mis-assert a security-load-bearing fail-closed case.
SANDBOX_IN_REPO=0
if git -C "$SANDBOX" rev-parse --show-toplevel >/dev/null 2>&1; then
    SANDBOX_IN_REPO=1
    echo "WARN: SANDBOX ($SANDBOX) is inside a git repo — SKIPPING the unbounded-walk-up cases T4/T13/T14 (they would escape into the enclosing repo and mis-assert)."
fi

mkrepo() { # $1=path $2=branch  (unborn HEAD on the given branch — no commit)
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" symbolic-ref HEAD "refs/heads/$2"
}

# rc_of FILE [EXTRA_ENV...] — run the hook on FILE, echo its exit code. Extra
# `KEY=VAL` env assignments (CLAUDE_PROJECT_DIR, CANON_FORCE, EDIT_ON_MAIN_OK …)
# may follow; CLAUDE_PROJECT_DIR is deliberately set to misleading values in the
# nesting/sibling cases to prove the hook ignores it.
rc_of() {
    local file="$1"; shift
    printf '%s' "{\"tool_input\":{\"file_path\":\"$file\"}}" \
        | env "$@" bash "$HOOK" >/dev/null 2>&1
    echo "$?"
}

# Repos under the sandbox.
mkrepo "$SANDBOX/mainrepo" main
mkrepo "$SANDBOX/featrepo" feat/x
mkrepo "$SANDBOX/masterrepo" master
mkdir -p "$SANDBOX/mainrepo/src" "$SANDBOX/mainrepo/handovers" "$SANDBOX/plain"

# Himmel#45: a nested repo on main, inside an OUTER repo on a feature branch
# (the launch dir the OLD code read).
mkrepo "$SANDBOX/outer" feat/o
mkrepo "$SANDBOX/outer/sc/nested" main
mkdir -p "$SANDBOX/outer/sc/nested/src"

# Inverse nesting: a nested repo on a FEATURE branch inside an OUTER repo on main.
mkrepo "$SANDBOX/outer2" main
mkrepo "$SANDBOX/outer2/sc/nested" feat/n
mkdir -p "$SANDBOX/outer2/sc/nested/src"

# A real git worktree on a feature branch (needs a commit to add the worktree).
mkrepo "$SANDBOX/wtrepo" main
git -C "$SANDBOX/wtrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$SANDBOX/wtrepo" worktree add -q "$SANDBOX/wtrepo/.claude/worktrees/feat+x" -b feat/x >/dev/null 2>&1
mkdir -p "$SANDBOX/wtrepo/.claude/worktrees/feat+x/src"

# A repo with a removed HEAD → branch unreadable (is_on_main rc=2).
mkrepo "$SANDBOX/brokenrepo" main
mkdir -p "$SANDBOX/brokenrepo/src"
rm -f "$SANDBOX/brokenrepo/.git/HEAD"

# T1: file in a repo on main → BLOCK
assert_rc "T1 main-repo edit blocks" 2 "$(rc_of "$SANDBOX/mainrepo/src/foo.js")"

# T2: file in a repo on a feature branch → ALLOW
assert_rc "T2 feature-repo edit allows" 0 "$(rc_of "$SANDBOX/featrepo/foo.js")"

# T3 (Himmel#45 regression): nested repo on main, launched from the OUTER repo
# (on a feature branch). The hook must read the NESTED repo's branch → BLOCK,
# even though CLAUDE_PROJECT_DIR points at the outer feature-branch dir. The old
# launch-dir-anchored code returned rc=0 (ALLOW) here — the reported bug.
assert_rc "T3 nested-on-main under outer-feature blocks (Himmel#45)" 2 \
    "$(rc_of "$SANDBOX/outer/sc/nested/src/foo.js" CLAUDE_PROJECT_DIR="$SANDBOX/outer")"

# T3b (inverse): nested repo on a FEATURE branch inside an outer repo on MAIN —
# must ALLOW. Guards against a regression that re-anchors to a parent/outer repo
# instead of the launch dir specifically (which would wrongly BLOCK this edit).
assert_rc "T3b nested-on-feature under outer-main allows" 0 \
    "$(rc_of "$SANDBOX/outer2/sc/nested/src/foo.js" CLAUDE_PROJECT_DIR="$SANDBOX/outer2")"

# T3c (sibling): launched in a feature-branch repo, editing a file in an
# UNRELATED repo on main → BLOCK. Proves the launch dir is ignored even with no
# nesting relationship.
assert_rc "T3c sibling repo on main blocks (launch dir ignored)" 2 \
    "$(rc_of "$SANDBOX/mainrepo/src/foo.js" CLAUDE_PROJECT_DIR="$SANDBOX/featrepo")"

# T4: file not inside any git repo → ALLOW
if [ "$SANDBOX_IN_REPO" -eq 0 ]; then
    assert_rc "T4 outside any repo allows" 0 "$(rc_of "$SANDBOX/plain/foo.js")"
else
    echo "SKIP T4 (SANDBOX inside a repo)"
fi

# T5: file inside a real git worktree (feature branch) → ALLOW (the worktree's
# own `.git` file is found by the walk; branch check allows via rc=1).
assert_rc "T5 worktree (feature branch) edit allows" 0 \
    "$(rc_of "$SANDBOX/wtrepo/.claude/worktrees/feat+x/src/foo.js")"

# T6: handover doc in a main repo → ALLOW (operator may edit docs from primary).
assert_rc "T6 handover doc on main allows" 0 "$(rc_of "$SANDBOX/mainrepo/handovers/status.md")"

# T7: new file in a not-yet-existing nested dir of a main repo → BLOCK
# (the `.git` walk skips the missing dirs and finds the repo root).
assert_rc "T7 new file in new subdir on main blocks" 2 "$(rc_of "$SANDBOX/mainrepo/new/deep/foo.js")"

# T7b: same shape but in a FEATURE repo → ALLOW (the walk doesn't over-shoot to a
# parent; it stops at the feature repo's own .git).
assert_rc "T7b new file in new subdir on feature allows" 0 "$(rc_of "$SANDBOX/featrepo/new/deep/foo.js")"

# T8: bypass on a main repo → ALLOW, and T8b: with zero stderr.
assert_rc "T8 bypass allows" 0 "$(rc_of "$SANDBOX/mainrepo/src/foo.js" EDIT_ON_MAIN_OK=1)"
stderr_bytes=$(printf '%s' "{\"tool_input\":{\"file_path\":\"$SANDBOX/mainrepo/src/foo.js\"}}" \
    | env EDIT_ON_MAIN_OK=1 bash "$HOOK" 2>&1 >/dev/null | wc -c)
assert_rc "T8b bypass silent stderr" 0 "$stderr_bytes"

# T9: NotebookEdit uses notebook_path → BLOCK on main.
rc=$(printf '%s' "{\"tool_input\":{\"notebook_path\":\"$SANDBOX/mainrepo/x.ipynb\"}}" \
    | bash "$HOOK" >/dev/null 2>&1; echo "$?")
assert_rc "T9 NotebookEdit on main blocks" 2 "$rc"

# T10: missing file_path → ALLOW silently.
rc=$(printf '%s' '{"tool_input":{}}' | bash "$HOOK" >/dev/null 2>&1; echo "$?")
assert_rc "T10 missing file_path allows" 0 "$rc"

# T11: master is protected too → BLOCK.
assert_rc "T11 master-repo edit blocks" 2 "$(rc_of "$SANDBOX/masterrepo/foo.js")"

# T12: traversal that resolves INTO a main repo → BLOCK (canon applied; `..`
# cannot escape the worktrees/ prefix into an allow).
assert_rc "T12 traversal into main repo blocks" 2 \
    "$(rc_of "$SANDBOX/mainrepo/.claude/worktrees/../foo.sh")"

# T13: traversal that resolves OUT to a non-repo path → ALLOW.
if [ "$SANDBOX_IN_REPO" -eq 0 ]; then
    assert_rc "T13 traversal out to non-repo allows" 0 \
        "$(rc_of "$SANDBOX/mainrepo/../plain/foo.js")"
else
    echo "SKIP T13 (SANDBOX inside a repo)"
fi

# T14: branch-unreadable repo (HEAD removed) → fail CLOSED (rc=2) with the
# "cannot determine branch" message. The `.git` walk finds the (broken) repo's
# `.git`, so is_on_main is invoked on it; with HEAD gone, _branch's very first
# step (`git rev-parse --absolute-git-dir`) returns rc=128 → _branch returns 2 →
# is_on_main rc=2 → fail closed. Distinct from "not a repo" (T4 → allow). SKIP
# when SANDBOX is inside a repo: there git's walk-up would escape the broken
# .git to the enclosing repo and read a real branch (masking the fail-closed).
if [ "$SANDBOX_IN_REPO" -eq 0 ]; then
    err=$(printf '%s' "{\"tool_input\":{\"file_path\":\"$SANDBOX/brokenrepo/src/foo.js\"}}" | bash "$HOOK" 2>&1 >/dev/null); rc=$?
    assert_rc "T14 unreadable branch fails closed" 2 "$rc"
    case "$err" in
        *"cannot determine branch"*) echo "PASS T14 refusal message" ;;
        *) echo "FAIL T14 refusal message — got: $err"; FAILED=$((FAILED + 1)) ;;
    esac
else
    echo "SKIP T14 (SANDBOX inside a repo)"
fi

# --- Cross-canonicaliser coverage: force the python3 canon branch end-to-end
# (main → block, feature → allow). Skip if python3 not on the runner.
if command -v python3 >/dev/null 2>&1; then
    assert_rc "T15 python3 canon — main blocks" 2 \
        "$(rc_of "$SANDBOX/mainrepo/src/foo.js" CANON_FORCE=python3)"
    assert_rc "T15b python3 canon — feature allows" 0 \
        "$(rc_of "$SANDBOX/featrepo/foo.js" CANON_FORCE=python3)"
else
    echo "SKIP T15 (no python3 on PATH)"
fi

# --- Fail-CLOSED coverage. CANON_FORCE to an unknown mode triggers canon()'s
# `*) return 1` arm → file_real empty → fail-closed exit 2.
assert_rc "T16 unknown CANON_MODE — fail closed" 2 \
    "$(rc_of "$SANDBOX/mainrepo/src/foo.js" CANON_FORCE=does-not-exist)"

# --- Wedged-stub coverage (HIMMEL-249). A python3 that wedges (ignores TERM)
# must read as a fail-CLOSED block (rc=2 via empty canon output), bounded by the
# armor — never a hung hook.
if timeout --version 2>/dev/null | grep -qi coreutils; then
    WEDGE_BIN=$(mktemp -d)
    cat > "$WEDGE_BIN/python3" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep 30
EOF
    chmod +x "$WEDGE_BIN/python3"
    start=$(date +%s)
    rc=$(printf '%s' "{\"tool_input\":{\"file_path\":\"$SANDBOX/mainrepo/src/foo.js\"}}" \
        | env PATH="$WEDGE_BIN:$PATH" PY_ARMOR_TIMEOUT=1 PY_ARMOR_KILL_AFTER=1 \
          CANON_FORCE=python3 bash "$HOOK" >/dev/null 2>&1; echo "$?")
    elapsed=$(( $(date +%s) - start ))
    assert_rc "T17 wedged python3 stub fails closed" 2 "$rc"
    if [ "$elapsed" -lt 15 ]; then
        echo "PASS T17 bounded (${elapsed}s)"
    else
        echo "FAIL T17 bounded — took ${elapsed}s"
        FAILED=$((FAILED + 1))
    fi
    rm -rf "$WEDGE_BIN" 2>/dev/null || true
else
    echo "SKIP T17 (no GNU coreutils timeout on this runner)"
fi

# --- Missing py-armor lib (HIMMEL-249). An unguarded source under set -e exits
# rc=1, which PreToolUse does NOT block on — fail OPEN. The guard must fail
# CLOSED (rc=2 + recognisable message).
LIBLESS=$(mktemp -d)
mkdir -p "$LIBLESS/hooks" "$LIBLESS/guardrails"
cp "$HOOK" "$LIBLESS/hooks/"
cp "$(dirname "$HOOK")/../guardrails/lib.sh" "$LIBLESS/guardrails/"
err=$(printf '%s' "{\"tool_input\":{\"file_path\":\"$SANDBOX/mainrepo/src/foo.js\"}}" | bash "$LIBLESS/hooks/block-edit-on-main.sh" 2>&1 >/dev/null); rc=$?
assert_rc "T18 missing py-armor lib fails closed" 2 "$rc"
case "$err" in
    *"cannot source py-armor.sh"*) echo "PASS T18 refusal message" ;;
    *) echo "FAIL T18 refusal message — got: $err"; FAILED=$((FAILED + 1)) ;;
esac
rm -rf "$LIBLESS" 2>/dev/null || true

# --- Missing guardrails/lib.sh. Same fail-CLOSED contract.
GUARDRAILLESS=$(mktemp -d)
mkdir -p "$GUARDRAILLESS/hooks" "$GUARDRAILLESS/lib"
cp "$HOOK" "$GUARDRAILLESS/hooks/"
cp "$(dirname "$HOOK")/../lib/py-armor.sh" "$GUARDRAILLESS/lib/" 2>/dev/null || true
err=$(printf '%s' "{\"tool_input\":{\"file_path\":\"$SANDBOX/mainrepo/src/foo.js\"}}" | bash "$GUARDRAILLESS/hooks/block-edit-on-main.sh" 2>&1 >/dev/null); rc=$?
assert_rc "T19 missing guardrails lib fails closed" 2 "$rc"
case "$err" in
    *"cannot source guardrails/lib.sh"*) echo "PASS T19 refusal message" ;;
    *) echo "FAIL T19 refusal message — got: $err"; FAILED=$((FAILED + 1)) ;;
esac
rm -rf "$GUARDRAILLESS" 2>/dev/null || true

# Clean up the worktree registration before removing the sandbox (avoids a
# dangling `git worktree` admin record under SANDBOX/wtrepo).
git -C "$SANDBOX/wtrepo" worktree remove --force "$SANDBOX/wtrepo/.claude/worktrees/feat+x" 2>/dev/null || true
rm -rf "$SANDBOX" 2>/dev/null || true

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
