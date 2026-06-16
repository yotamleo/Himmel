#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-platforms-tested.sh.
#
# Builds a throwaway git repo with a main branch, a feature branch, and
# controlled commit messages, then runs the hook from inside it.
#
# Usage: bash scripts/hooks/test-check-platforms-tested.sh
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/check-platforms-tested.sh"
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

# Build a temp repo with: main has README, feature branch adds files +
# commits with $msg. Run hook from feature branch HEAD.
make_repo() {
    local files="$1" msg="$2"
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
        git checkout -q -b feat/x
        # shellcheck disable=SC2086 # files is space-separated, intentional split
        for f in $files; do
            mkdir -p "$(dirname "$f")"
            echo "x" > "$f"
        done
        git add -A
        # shellcheck disable=SC2086 # files is space-separated
        git -c commit.gpgsign=false commit -q -m "$msg"
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

# --- BLOCK cases (rc=1) ---
d=$(make_repo "scripts/foo.sh" "feat: add foo")
assert_rc "sensitive .sh + no attestation"            1 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "x.ps1" "feat: add ps1")
assert_rc "sensitive .ps1 + no attestation"           1 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "scripts/sub/foo.sh" "feat: nested sh")
assert_rc "scripts/ nested + no attestation"          1 "$(run_in "$d")"
rm -rf "$d"

# --- ALLOW cases (rc=0) ---
d=$(make_repo "src/foo.ts" "feat: ts only")
assert_rc "non-sensitive file"                        0 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "README.md" "docs: readme")
assert_rc "docs only"                                 0 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "scripts/foo.sh" "$(printf 'feat: foo\n\nPlatforms tested: linux, windows\n')")
assert_rc "sensitive + attestation linux+windows"     0 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "scripts/foo.sh" "$(printf 'feat: foo\n\nPlatforms tested: gitbash (msys2), wsl\n')")
assert_rc "sensitive + attestation gitbash/wsl"       0 "$(run_in "$d")"
rm -rf "$d"

# Post-CR: empty / unrecognised values do NOT satisfy the gate.
d=$(make_repo "scripts/foo.sh" "$(printf 'feat: foo\n\nPlatforms tested:\n')")
assert_rc "sensitive + empty attestation = block"     1 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "scripts/foo.sh" "$(printf 'feat: foo\n\nPlatforms tested: yes\n')")
assert_rc "sensitive + unrecognised value = block"    1 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "scripts/foo.sh" "$(printf 'feat: foo\n\n[skip platforms-check]\n')")
assert_rc "sensitive + skip marker"                   0 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "scripts/foo.sh" "feat: foo")
assert_rc "sensitive + env bypass"                    0 "$(run_in "$d" "PLATFORMS_TESTED_OK=1")"
rm -rf "$d"

# --- HIMMEL-113: linked-worktree scenarios (local main behind origin/main) ---
#
# Build a bare "origin", clone it, advance origin/main by one commit that
# touches a sensitive file, then create a feature branch off the OLD local
# main that touches only non-sensitive files. Pre-HIMMEL-113 (when the hook
# diffed against local main) this re-flagged the origin-only sensitive file
# as belonging to the push. Post-HIMMEL-113 (diff against origin/main)
# the gate ignores it correctly.
d=$(mktemp -d)
origin=$(mktemp -d)
(
    cd "$origin" || exit 1
    git init -q --bare -b main
) >/dev/null 2>&1
(
    cd "$d" || exit 1
    git clone -q "$origin" . >/dev/null 2>&1
    git config user.email t@t
    git config user.name t
    echo r > README.md
    git add README.md
    git -c commit.gpgsign=false commit -q -m "init"
    git push -q origin main >/dev/null 2>&1
    # Branch off here so local main is "behind" after the next push.
    git checkout -q -b feat/x
    echo "non-sensitive ts" > src.ts
    git add src.ts
    git -c commit.gpgsign=false commit -q -m "feat: non-sensitive change"
    # Advance origin/main with a SENSITIVE-file commit (simulating another
    # PR landed) — local main does NOT have it.
    git checkout -q main
    mkdir -p scripts
    echo "other change" > scripts/other.sh
    git add scripts/other.sh
    git -c commit.gpgsign=false commit -q -m "feat: other shell change on main"
    git push -q origin main >/dev/null 2>&1
    # Pretend the operator never fetched: rewind local main to BEFORE that
    # commit, so local main is now strictly behind origin/main.
    git reset -q --hard HEAD~1
    git checkout -q feat/x
    git fetch -q origin main >/dev/null 2>&1
) >/dev/null 2>&1
# Skip the in-hook fetch so the test is offline-deterministic; we already
# fetched origin/main above.
assert_rc "linked-worktree: feat non-sensitive, ignore origin-only sh" 0 "$(run_in "$d" "PLATFORMS_TESTED_NO_FETCH=1")"
rm -rf "$d" "$origin"

# Same setup but feature branch touches a SENSITIVE file (genuine gate
# should still trigger).
d=$(mktemp -d)
origin=$(mktemp -d)
(
    cd "$origin" || exit 1
    git init -q --bare -b main
) >/dev/null 2>&1
(
    cd "$d" || exit 1
    git clone -q "$origin" . >/dev/null 2>&1
    git config user.email t@t
    git config user.name t
    echo r > README.md
    git add README.md
    git -c commit.gpgsign=false commit -q -m "init"
    git push -q origin main >/dev/null 2>&1
    git checkout -q -b feat/x
    mkdir -p scripts
    echo "my change" > scripts/mine.sh
    git add scripts/mine.sh
    git -c commit.gpgsign=false commit -q -m "feat: my shell change"
    git checkout -q main
    mkdir -p scripts
    echo "other" > scripts/other.sh
    git add scripts/other.sh
    git -c commit.gpgsign=false commit -q -m "feat: other shell change on main"
    git push -q origin main >/dev/null 2>&1
    git reset -q --hard HEAD~1
    git checkout -q feat/x
    git fetch -q origin main >/dev/null 2>&1
) >/dev/null 2>&1
assert_rc "linked-worktree: feat has sensitive sh, still blocks"      1 "$(run_in "$d" "PLATFORMS_TESTED_NO_FETCH=1")"
rm -rf "$d" "$origin"

# PLATFORMS_TESTED_NO_FETCH=1 with no origin (offline workflow) falls
# back to local main and behaves like before.
d=$(make_repo "scripts/foo.sh" "feat: add foo")
assert_rc "no-fetch + no origin -> fall back to local main"           1 "$(run_in "$d" "PLATFORMS_TESTED_NO_FETCH=1")"
rm -rf "$d"

# Main-branch push: skip. Make a repo where HEAD is main.
d=$(mktemp -d)
(
    cd "$d" || exit 1
    git init -q -b main
    git config user.email t@t
    git config user.name t
    echo r > scripts/foo.sh
    git add -A
    git -c commit.gpgsign=false commit -q -m "feat: foo"
) >/dev/null 2>&1
assert_rc "on main branch — skip"                     0 "$(run_in "$d")"
rm -rf "$d"

# --- HIMMEL-297: master-default repo ---
# A repo whose default branch is master (no main ref at all). Pre-fix the hook
# found neither origin/main nor local main and SKIPPED (false pass). Post-fix
# default_branch resolves master, so a sensitive file with no attestation still
# BLOCKS, and a push while sitting on master is skipped.
make_master_repo() {
    local files="$1" msg="$2" dir
    dir=$(mktemp -d)
    (
        cd "$dir" || exit 1
        git init -q -b master
        git config user.email t@t
        git config user.name t
        echo r > README.md
        git add README.md
        git -c commit.gpgsign=false commit -q -m "init"
        git checkout -q -b feat/x
        # shellcheck disable=SC2086 # files is space-separated, intentional split
        for f in $files; do
            mkdir -p "$(dirname "$f")"
            echo "x" > "$f"
        done
        git add -A
        git -c commit.gpgsign=false commit -q -m "$msg"
    )
    echo "$dir"
}

d=$(make_master_repo "scripts/foo.sh" "feat: add foo")
assert_rc "master-default: sensitive .sh + no attestation = block (base resolved to master)" 1 "$(run_in "$d" "PLATFORMS_TESTED_NO_FETCH=1")"
rm -rf "$d"

# On master branch: skip (master is a protected default too).
d=$(mktemp -d)
(
    cd "$d" || exit 1
    git init -q -b master
    git config user.email t@t
    git config user.name t
    mkdir -p scripts
    echo r > scripts/foo.sh
    git add -A
    git -c commit.gpgsign=false commit -q -m "feat: foo"
) >/dev/null 2>&1
assert_rc "on master branch — skip"                   0 "$(run_in "$d")"
rm -rf "$d"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
