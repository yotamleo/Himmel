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

# T2: feature branch in the PRIMARY checkout (its `.git` is a directory) → BLOCK
# (HIMMEL-507: feature work belongs in a worktree, not a branch checked out in
# the primary tree). T2b asserts the message names the feature-branch case,
# distinct from the on-main message.
assert_rc "T2 feature branch in primary checkout blocks (HIMMEL-507)" 2 "$(rc_of "$SANDBOX/featrepo/foo.js")"
t2err=$(printf '%s' "{\"tool_input\":{\"file_path\":\"$SANDBOX/featrepo/foo.js\"}}" | bash "$HOOK" 2>&1 >/dev/null)
case "$t2err" in
    *"on a feature branch"*) echo "PASS T2b primary-feature block message" ;;
    *) echo "FAIL T2b primary-feature block message — got: $t2err"; FAILED=$((FAILED + 1)) ;;
esac

# T3 (Himmel#45 regression): nested repo on main, launched from the OUTER repo
# (on a feature branch). The hook must read the NESTED repo's branch → BLOCK,
# even though CLAUDE_PROJECT_DIR points at the outer feature-branch dir. The old
# launch-dir-anchored code returned rc=0 (ALLOW) here — the reported bug.
assert_rc "T3 nested-on-main under outer-feature blocks (Himmel#45)" 2 \
    "$(rc_of "$SANDBOX/outer/sc/nested/src/foo.js" CLAUDE_PROJECT_DIR="$SANDBOX/outer")"

# T3b (inverse): nested repo on a FEATURE branch (a PRIMARY checkout) inside an
# outer repo on MAIN. Post-HIMMEL-507 BOTH branches block, so the rc alone no
# longer proves anchoring — assert the MESSAGE is the primary-feature one. If
# the hook wrongly re-anchored to the outer (main) repo it would print the
# on-main message instead, so this still guards the Himmel#45 anchoring.
assert_rc "T3b nested-on-feature in primary blocks (HIMMEL-507)" 2 \
    "$(rc_of "$SANDBOX/outer2/sc/nested/src/foo.js" CLAUDE_PROJECT_DIR="$SANDBOX/outer2")"
t3berr=$(printf '%s' "{\"tool_input\":{\"file_path\":\"$SANDBOX/outer2/sc/nested/src/foo.js\"}}" \
    | env CLAUDE_PROJECT_DIR="$SANDBOX/outer2" bash "$HOOK" 2>&1 >/dev/null)
case "$t3berr" in
    *"on a feature branch"*) echo "PASS T3b message proves nested-repo anchoring (not outer-main)" ;;
    *) echo "FAIL T3b anchoring message — got: $t3berr"; FAILED=$((FAILED + 1)) ;;
esac

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

# T5: file inside a real git worktree (feature branch) → ALLOW. The worktree's
# own `.git` is a FILE (not a directory), so the HIMMEL-507 primary-checkout
# block does not apply — a linked worktree is exactly where feature work belongs.
# This is the case T2 (feature branch in the PRIMARY checkout) contrasts with.
assert_rc "T5 worktree (feature branch) edit allows" 0 \
    "$(rc_of "$SANDBOX/wtrepo/.claude/worktrees/feat+x/src/foo.js")"

# T6: handover doc in a main repo → ALLOW (operator may edit docs from primary).
assert_rc "T6 handover doc on main allows" 0 "$(rc_of "$SANDBOX/mainrepo/handovers/status.md")"

# T7: new file in a not-yet-existing nested dir of a main repo → BLOCK
# (the `.git` walk skips the missing dirs and finds the repo root).
assert_rc "T7 new file in new subdir on main blocks" 2 "$(rc_of "$SANDBOX/mainrepo/new/deep/foo.js")"

# T7b: same shape but in a FEATURE repo (primary checkout) → BLOCK post-HIMMEL-507
# (the walk stops at the feature repo's own `.git` directory → primary-feature block;
# it does not over-shoot to a parent). T7c: the SAME new-subdir shape inside a linked
# worktree → ALLOW (worktree `.git` is a file), confirming the walk + the file/dir
# distinction both work for a not-yet-existing target.
assert_rc "T7b new file in new subdir on feature-primary blocks (HIMMEL-507)" 2 "$(rc_of "$SANDBOX/featrepo/new/deep/foo.js")"
assert_rc "T7c new file in new subdir inside a worktree allows" 0 \
    "$(rc_of "$SANDBOX/wtrepo/.claude/worktrees/feat+x/new/deep/foo.js")"

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
# (main → block; worktree → allow). The allow path uses the worktree (not a
# feature-branch primary checkout, which now blocks per HIMMEL-507) so python
# canon still exercises a real ALLOW. Skip if python3 not on the runner.
if command -v python3 >/dev/null 2>&1; then
    assert_rc "T15 python3 canon — main blocks" 2 \
        "$(rc_of "$SANDBOX/mainrepo/src/foo.js" CANON_FORCE=python3)"
    assert_rc "T15b python3 canon — worktree allows" 0 \
        "$(rc_of "$SANDBOX/wtrepo/.claude/worktrees/feat+x/src/foo.js" CANON_FORCE=python3)"
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

# --- HIMMEL-404: .single-writer opt-in cases ---

# A nested repo for the "parent has marker but nested lacks it" case.
mkrepo "$SANDBOX/swparent" main
mkrepo "$SANDBOX/swparent/sc/nested" main
mkdir -p "$SANDBOX/swparent/sc/nested/src"
touch "$SANDBOX/swparent/.single-writer"   # marker on the PARENT only

# T20: single-writer marker present on main → ALLOW.
mkrepo "$SANDBOX/swrepo" main
touch "$SANDBOX/swrepo/.single-writer"
mkdir -p "$SANDBOX/swrepo/src"
assert_rc "T20 single-writer marker present on main allows" 0 \
    "$(rc_of "$SANDBOX/swrepo/src/foo.md")"

# T21: single-writer marker absent on main → BLOCK.
mkrepo "$SANDBOX/nswrepo" main
mkdir -p "$SANDBOX/nswrepo/src"
assert_rc "T21 single-writer marker absent on main blocks" 2 \
    "$(rc_of "$SANDBOX/nswrepo/src/foo.md")"

# T22: nested repo on main without its own marker → BLOCK even though the
# parent repo has a .single-writer. Anchored to the edited file's repo (repo_real),
# so the parent's marker must never leak the opt-out onto the nested repo.
assert_rc "T22 nested repo without own marker blocks (parent marker does not leak)" 2 \
    "$(rc_of "$SANDBOX/swparent/sc/nested/src/foo.md" CLAUDE_PROJECT_DIR="$SANDBOX/swparent")"

# T23: EDIT_ON_MAIN_OK=1 allows without a .single-writer marker (pre-existing bypass
# still works when the repo has no marker — regression guard).
assert_rc "T23 EDIT_ON_MAIN_OK=1 allows with no marker" 0 \
    "$(rc_of "$SANDBOX/nswrepo/src/foo.md" EDIT_ON_MAIN_OK=1)"

# T24: .single-writer is a DIRECTORY → fail-CLOSED (BLOCK).
# [ -f ] is false for a directory; the hook must not treat a mis-shaped marker
# as an opt-out. Design doc names this case explicitly as fail-closed.
mkrepo "$SANDBOX/swdir" main
mkdir -p "$SANDBOX/swdir/.single-writer"   # marker is a directory, not a file
mkdir -p "$SANDBOX/swdir/src"
assert_rc "T24 dir-shaped marker on main blocks (fail-closed)" 2 \
    "$(rc_of "$SANDBOX/swdir/src/foo.md")"

# T25: .single-writer present + FEATURE branch in the PRIMARY checkout → ALLOW
# via the marker opt-out. Post-HIMMEL-507 this case would otherwise BLOCK (a
# feature branch in the primary tree), so this proves the .single-writer opt-out
# covers the new primary-feature block path too, not just on-main. Paired with
# T21 (no marker, would-block → block) and T20 (marker, main → allow).
mkrepo "$SANDBOX/swfeat" feat/x
touch "$SANDBOX/swfeat/.single-writer"
assert_rc "T25 marker present on feature-branch primary allows (opt-out covers HIMMEL-507)" 0 \
    "$(rc_of "$SANDBOX/swfeat/foo.md")"

# T26: EDIT_ON_MAIN_OK=1 + marker present on main → ALLOW via env bypass.
# Confirms the env bypass fires regardless of whether a .single-writer marker
# is present — closes the spec sentence "EDIT_ON_MAIN_OK=1 still allows
# regardless of marker". Reuses swrepo (has marker, on main).
assert_rc "T26 EDIT_ON_MAIN_OK=1 + marker present allows (env bypass wins)" 0 \
    "$(rc_of "$SANDBOX/swrepo/src/foo.md" EDIT_ON_MAIN_OK=1)"

# T27 (HIMMEL-507): EDIT_ON_MAIN_OK=1 bypasses the feature-branch-in-primary
# block too (no marker present) — confirms the env bypass covers the new block
# path, mirroring T23 (bypass on main with no marker). featrepo is a primary
# checkout on a feature branch with no .single-writer.
assert_rc "T27 EDIT_ON_MAIN_OK=1 allows feature branch in primary (HIMMEL-507)" 0 \
    "$(rc_of "$SANDBOX/featrepo/foo.js" EDIT_ON_MAIN_OK=1)"

# --- HIMMEL-876: untracked+gitignored exemption cases ---

# T28: TRACKED file on main -> BLOCK, even when it also matches a .gitignore
# pattern (force-added). Proves `ls-files --error-unmatch` (tracked) wins over
# `check-ignore` — a tracked file is never exempted, since it CAN be committed.
mkrepo "$SANDBOX/trackedrepo" main
printf '*.local.json\n' > "$SANDBOX/trackedrepo/.gitignore"
printf '{}\n' > "$SANDBOX/trackedrepo/tracked.local.json"
git -C "$SANDBOX/trackedrepo" add -f .gitignore tracked.local.json
git -C "$SANDBOX/trackedrepo" -c user.email=t@t -c user.name=t commit -q -m init
assert_rc "T28 tracked file (even if gitignore-matching) on main blocks" 2 \
    "$(rc_of "$SANDBOX/trackedrepo/tracked.local.json")"

# T29: UNTRACKED + gitignored file on main -> ALLOW (the false-positive fix —
# mirrors the real HIMMEL-876 case, scripts/cr/critics.local.json).
mkrepo "$SANDBOX/ignoredrepo" main
printf '*.local.json\n' > "$SANDBOX/ignoredrepo/.gitignore"
git -C "$SANDBOX/ignoredrepo" add .gitignore
git -C "$SANDBOX/ignoredrepo" -c user.email=t@t -c user.name=t commit -q -m init
printf '{}\n' > "$SANDBOX/ignoredrepo/critics.local.json"
assert_rc "T29 untracked+gitignored file on main allows (HIMMEL-876)" 0 \
    "$(rc_of "$SANDBOX/ignoredrepo/critics.local.json")"

# T30: UNTRACKED but NOT gitignored file on main (repo HAS a .gitignore, just
# one that doesn't match this file) -> BLOCK. Could still be `git add`ed.
printf '{}\n' > "$SANDBOX/ignoredrepo/plain.js"
assert_rc "T30 untracked-but-not-ignored file on main blocks (HIMMEL-876)" 2 \
    "$(rc_of "$SANDBOX/ignoredrepo/plain.js")"

# T31: untracked+gitignored file on a FEATURE branch in the PRIMARY checkout
# (block_reason=primary-feature) -> ALLOW. Proves the exemption covers both
# block paths (mirrors T25's coverage of the .single-writer opt-out).
mkrepo "$SANDBOX/ignoredfeatrepo" feat/x
printf '*.local.json\n' > "$SANDBOX/ignoredfeatrepo/.gitignore"
git -C "$SANDBOX/ignoredfeatrepo" add .gitignore
git -C "$SANDBOX/ignoredfeatrepo" -c user.email=t@t -c user.name=t commit -q -m init
printf '{}\n' > "$SANDBOX/ignoredfeatrepo/critics.local.json"
assert_rc "T31 untracked+gitignored file on feature-branch primary allows (HIMMEL-876)" 0 \
    "$(rc_of "$SANDBOX/ignoredfeatrepo/critics.local.json")"

# T32: a git failure DURING the ls-files/check-ignore check (a stub `git` on
# PATH that fails just those two subcommands, real git otherwise) -> fail
# CLOSED (BLOCK). Uses ignoredrepo (has a real .gitignore match) to prove the
# would-be-exempted case still blocks when the check itself errors.
GITSTUB_BIN=$(mktemp -d)
REAL_GIT=$(command -v git)
cat > "$GITSTUB_BIN/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
    case "\$a" in
        ls-files|check-ignore) exit 129 ;;
    esac
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GITSTUB_BIN/git"
assert_rc "T32 git failure during untracked/ignore check fails closed (HIMMEL-876)" 2 \
    "$(rc_of "$SANDBOX/ignoredrepo/critics.local.json" PATH="$GITSTUB_BIN:$PATH")"
rm -rf "$GITSTUB_BIN" 2>/dev/null || true

# T33/T34: secret-class carve-out (HIMMEL-876 CR). An untracked+gitignored
# file whose basename is in the block-read-secrets.sh secret set (.env,
# id_ed25519, ...) NEVER takes the exemption — it stays BLOCKED on main,
# preserving the incidental protection of the real .env in the primary
# checkout from unattended clobbering.
mkrepo "$SANDBOX/secretrepo" main
printf '.env\nid_ed25519\n' > "$SANDBOX/secretrepo/.gitignore"
git -C "$SANDBOX/secretrepo" add .gitignore
git -C "$SANDBOX/secretrepo" -c user.email=t@t -c user.name=t commit -q -m init
printf 'KEY=x\n' > "$SANDBOX/secretrepo/.env"
printf 'key\n' > "$SANDBOX/secretrepo/id_ed25519"
assert_rc "T33 untracked+gitignored .env on main still blocks (secret carve-out)" 2 \
    "$(rc_of "$SANDBOX/secretrepo/.env")"
assert_rc "T34 untracked+gitignored id_ed25519 on main still blocks (secret carve-out)" 2 \
    "$(rc_of "$SANDBOX/secretrepo/id_ed25519")"

# T35: the non-secret allow case (T29's critics.local.json shape) still
# ALLOWS after the carve-out — the exemption itself is unchanged for the
# operator-local-state class it was built for. Also locks the lowercase
# fold in is_secret_basename: an already-lowercase non-secret basename
# must be unaffected by the case-insensitivity fix.
assert_rc "T35 untracked+gitignored critics.local.json still allows after carve-out" 0 \
    "$(rc_of "$SANDBOX/ignoredrepo/critics.local.json")"

# T36: stub ONLY check-ignore to fail (rc=128) while ls-files stays REAL and
# returns rc=1 (untracked) -> must still BLOCK. Locks the &&-short-circuit
# fail-closed guarantee: T32 fails ls-files first, so the check-ignore leg
# of the conjunction was never actually reached by a test until now.
CIONLY_BIN=$(mktemp -d)
REAL_GIT=$(command -v git)
cat > "$CIONLY_BIN/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
    case "\$a" in
        check-ignore) exit 128 ;;
    esac
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$CIONLY_BIN/git"
assert_rc "T36 check-ignore failure alone fails closed (ls-files real, HIMMEL-876)" 2 \
    "$(rc_of "$SANDBOX/ignoredrepo/critics.local.json" PATH="$CIONLY_BIN:$PATH")"
rm -rf "$CIONLY_BIN" 2>/dev/null || true

# T37: mixed-case secret basenames (.ENV, ID_RSA) untracked, with a lowercase
# gitignore, on main -> BLOCKED. On a case-INsensitive host (Windows/macOS,
# core.ignorecase=true) check-ignore folds .ENV onto the '.env' ignore line,
# so only the lowercased is_secret_basename carve-out denies; on a
# case-SENSITIVE host (Linux CI) .ENV is simply not ignored and the
# untracked-not-ignored fall-through denies. Either layer -> rc=2; the
# assertion is deliberately layer-agnostic.
mkrepo "$SANDBOX/casesecretrepo" main
printf '.env\nid_rsa\n' > "$SANDBOX/casesecretrepo/.gitignore"
git -C "$SANDBOX/casesecretrepo" add .gitignore
git -C "$SANDBOX/casesecretrepo" -c user.email=t@t -c user.name=t commit -q -m init
printf 'KEY=x\n' > "$SANDBOX/casesecretrepo/.ENV"
printf 'key\n' > "$SANDBOX/casesecretrepo/ID_RSA"
assert_rc "T37 untracked .ENV on main blocks (case-insensitive carve-out)" 2 \
    "$(rc_of "$SANDBOX/casesecretrepo/.ENV")"
assert_rc "T37b untracked ID_RSA on main blocks (case-insensitive carve-out)" 2 \
    "$(rc_of "$SANDBOX/casesecretrepo/ID_RSA")"

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
