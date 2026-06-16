#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-hookspath.sh.
#
# Builds throwaway git repos, sets core.hooksPath to controlled values,
# runs the hook from inside, asserts rc per case.
#
# Usage: bash scripts/hooks/test-check-hookspath.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/check-hookspath.sh"
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

# Build a temp repo: init, commit, optionally set core.hooksPath.
# Returns the toplevel path on stdout.
make_repo() {
    local hooks_path_setting="$1"  # empty string = leave unset
    local dir
    dir=$(mktemp -d)
    (
        cd "$dir" || exit 1
        git init -q -b main
        git config user.email t@t
        git config user.name t
        echo r > README.md
        git add README.md
        git -c commit.gpgsign=false commit -q -m "init"
        if [ -n "$hooks_path_setting" ]; then
            git config core.hooksPath "$hooks_path_setting"
        fi
    )
    echo "$dir"
}

run_in() {
    local dir="$1" env_assign="${2:-}"
    if [ -n "$env_assign" ]; then
        ( cd "$dir" && env "$env_assign" bash "$HOOK" >/dev/null 2>&1 )
    else
        ( cd "$dir" && bash "$HOOK" >/dev/null 2>&1 )
    fi
    echo "$?"
}

# --- T1: core.hooksPath unset → OK (rc=0) ---
d=$(make_repo "")
assert_rc "T1 unset"                                   0 "$(run_in "$d")"
rm -rf "$d"

# --- T2: core.hooksPath = existing path INSIDE repo → OK (rc=0) ---
d=$(make_repo "")
mkdir -p "$d/custom-hooks"
( cd "$d" && git config core.hooksPath "$d/custom-hooks" )
assert_rc "T2 set inside repo"                         0 "$(run_in "$d")"
rm -rf "$d"

# --- T2b: core.hooksPath = RELATIVE path inside repo → OK (rc=0) ---
# Mirrors the legit pre-commit-installed case where `.git/hooks` is
# referenced relatively from worktree-pwd.
d=$(make_repo "")
mkdir -p "$d/custom-hooks"
( cd "$d" && git config core.hooksPath custom-hooks )
assert_rc "T2b set inside repo (relative)"             0 "$(run_in "$d")"
rm -rf "$d"

# --- T3: core.hooksPath = NONEXISTENT path → FAIL (rc=1) ---
# This is the HIMMEL-45 reproduction: post-rename, the old absolute
# path no longer resolves to anything on disk.
d=$(make_repo "/this/path/does/not/exist/anywhere")
assert_rc "T3 nonexistent path"                        1 "$(run_in "$d")"
rm -rf "$d"

# --- T4: core.hooksPath = existing path OUTSIDE repo → FAIL (rc=1) ---
d=$(make_repo "")
outside=$(mktemp -d)
mkdir -p "$outside/hooks"
( cd "$d" && git config core.hooksPath "$outside/hooks" )
assert_rc "T4 outside repo"                            1 "$(run_in "$d")"
rm -rf "$d" "$outside"

# --- T5: HOOKSPATH_OK=1 bypass → OK silently (rc=0) ---
d=$(make_repo "/this/path/does/not/exist/anywhere")
assert_rc "T5 bypass on bad path"                      0 "$(run_in "$d" "HOOKSPATH_OK=1")"
rm -rf "$d"

# --- T6: not in a git repo at all → OK (rc=0) ---
# Outside any repo, `git config --get` returns nonzero / nothing. The
# hook should not fail noisily in that case (covers CI sandboxes etc.).
d=$(mktemp -d)
assert_rc "T6 not a git repo"                          0 "$(run_in "$d")"
rm -rf "$d"

# --- T7: linked worktree, hooksPath → primary repo .git/hooks → OK (rc=0) ---
# A `git worktree add`-created worktree shares the primary repo's .git
# directory (its `git-common-dir`). Pointing core.hooksPath at the
# primary repo's hooks dir (e.g. `<primary>/.git/hooks`) is the canonical
# pre-commit install location and must NOT trip the gate even though
# the path resolves outside the linked-worktree toplevel.
d=$(make_repo "")
# Pre-populate the primary repo's `.git/hooks` so the path-exists check
# in the hook passes. (git init creates it empty by default, but be
# explicit in case of a future change.)
mkdir -p "$d/.git/hooks"
# Create a linked worktree off main.
( cd "$d" && git worktree add -q ../linked-wt -b feat/probe >/dev/null 2>&1 )
linked_wt="$(dirname "$d")/linked-wt"
# Set the linked worktree's core.hooksPath to point at the primary repo
# hooks dir (absolute). This is the legit shared-hooks case.
( cd "$linked_wt" && git config core.hooksPath "$d/.git/hooks" )
assert_rc "T7 linked worktree -> primary git-common-dir/hooks" 0 "$(run_in "$linked_wt")"
( cd "$d" && { git worktree remove -f ../linked-wt >/dev/null 2>&1 || true; } )
rm -rf "$d" "$linked_wt"

# --- T8: hooksPath outside BOTH worktree toplevel AND git-common-dir → FAIL (rc=1) ---
# Sanity check: a truly out-of-tree absolute path must still be rejected.
# We construct: a real worktree at $d, a primary-style sibling repo, and
# an unrelated outside dir. Setting hooksPath to the outside dir must fail.
d=$(make_repo "")
outside=$(mktemp -d)
mkdir -p "$outside/hooks"
( cd "$d" && git config core.hooksPath "$outside/hooks" )
assert_rc "T8 outside both worktree-top and git-common-dir" 1 "$(run_in "$d")"
rm -rf "$d" "$outside"

# --- T9: Windows drive-relative path "C:foo" → treated as RELATIVE (rc=0) ---
# Drive-relative paths (no separator after the colon, e.g. "C:custom-hooks")
# are NOT absolute on Windows — they resolve against the cwd of the drive,
# not the drive root. The hook used to mis-classify them as absolute via
# a too-loose `[A-Za-z]:*` case pattern. With the fix, they're treated as
# relative and joined to the worktree toplevel.
#
# To prove the JOIN actually happens, we create the literal directory
# "C:custom-hooks" inside the worktree first. If the hook (correctly)
# treats the value as relative, it joins → "$d/C:custom-hooks", which
# exists → rc=0. If it (incorrectly) treats it as absolute, it leaves
# the value as "C:custom-hooks", which Git Bash resolves to the cwd of
# drive C: — almost never the worktree dir — → "does not exist" → rc=1.
# The case-pattern fix is platform-independent; this assertion holds on
# Linux too (literal "C:" in a directory name is legal POSIX).
d=$(make_repo "")
mkdir -p "$d/C:custom-hooks"
( cd "$d" && git config core.hooksPath "C:custom-hooks" )
assert_rc "T9 drive-relative path treated as relative" 0 "$(run_in "$d")"
rm -rf "$d"

# --- T10: Windows-shape mixed-case absolute prefix → OK (rc=0) ---
# NTFS is case-insensitive. If the operator types
# `git config core.hooksPath c:/users/<user>/.../custom-hooks` but the
# worktree resolves to `C:/Users/<user>/.../custom-hooks`, the prefix
# check used to fail because shell `case` glob matching is
# byte-exact. With the case-insensitive prefix fix on Windows, both
# sides downcase before compare → match → rc=0.
#
# Skip on non-Windows: the fix is Windows-only (POSIX filesystems are
# case-sensitive, and we don't want to mask a real case-mismatch bug
# on Linux/macOS).
if [ "${OS-}" = "Windows_NT" ] || case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) true;; *) false;; esac; then
    d=$(make_repo "")
    mkdir -p "$d/custom-hooks"
    # Downcase the absolute path. mktemp on Git Bash returns e.g.
    # `/tmp/tmp.XXXX` which canonicalises to `C:/Users/<user>/AppData/Local/Temp/...`
    # via realpath -m. We want to set hooksPath to a lowercased version
    # of a real subdir so realpath resolves it (NTFS case-insensitive)
    # but the resulting canonical string differs in case from real_top.
    #
    # Strategy: canonicalise the worktree once, then set hooksPath to
    # the lowercased canonical-form/custom-hooks. realpath -m will
    # preserve the (lowercased) input casing on Git Bash, so real_val
    # differs from real_top in case — exercising the fix.
    canon_top=$(realpath -m "$d")
    lower_hooks=$(printf '%s/custom-hooks' "$canon_top" | tr '[:upper:]' '[:lower:]')
    ( cd "$d" && git config core.hooksPath "$lower_hooks" )
    assert_rc "T10 Windows mixed-case prefix"           0 "$(run_in "$d")"
    rm -rf "$d"
else
    echo "SKIP T10 (non-Windows)"
fi

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
