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

# INDENTED skip marker (CodeRabbit on the HIMMEL-1115 PR). The predicate's
# `^[[:space:]]*` is meant to tolerate leading whitespace; it used the GNU-only
# `\s`, which BSD grep (macOS) reads as a LITERAL 's' — degrading `^\s*` to
# `^s*`, which still matched an UNINDENTED marker (zero 's') and so looked
# correct, while silently failing on an indented one.
# HONEST CAVEAT: this case canNOT fail on a GNU-grep box (Git Bash/Linux
# accept `\s`), so it is NOT a red-provable regression test here — it pins the
# documented "leading whitespace is allowed" contract and would catch the
# regression on macOS/BSD.
d=$(make_repo "scripts/foo.sh" "$(printf 'feat: foo\n\n    [skip platforms-check]\n')")
assert_rc "sensitive + INDENTED skip marker (BSD-grep safe)" 0 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "scripts/foo.sh" "feat: foo")
assert_rc "sensitive + env bypass"                    0 "$(run_in "$d" "PLATFORMS_TESTED_OK=1")"
rm -rf "$d"

# --- HIMMEL-1115: a >64KB commit-message range must not SIGPIPE the gate ---
#
# Regression. The gate used to test the attestation with
#   printf '%s' "$commit_msgs" | grep -qiE "$ATTEST_RE"
# under `set -euo pipefail`. Once the range's messages exceed the OS pipe
# buffer (~64KB), printf BLOCKS mid-write; grep -q matches the attestation
# early (git log is newest-first and the attestation lives in the NEWEST
# commit) and exits immediately; the blocked printf then takes SIGPIPE and
# dies 141; pipefail promotes that 141 to the pipeline's status. The `if`
# therefore went FALSE *because* the attestation was found, and found early
# — blocking a correctly-attested push, and getting likelier to do so the
# MORE diligently the operator attested (every extra trailer grows the
# range). Observed on PR #1242 at 76,283 bytes after ~22 attested commits.
#
# The fixture mirrors that exact shape: bulk in the older commit, the
# attestation in the newest. It FAILS against the pre-fix hook (rc=1) — that
# is the point of it.
d=$(mktemp -d)
(
    cd "$d" || exit 1
    git init -q -b main
    git config user.email t@t
    git config user.name t
    echo r > README.md
    git add README.md
    git -c commit.gpgsign=false commit -q -m "init"
    git checkout -q -b feat/x
    mkdir -p scripts
    echo x > scripts/foo.sh
    git add -A
    # ~136KB of earlier commit-message bulk, carrying NO attestation itself.
    # Written via `commit -F <file>`, NOT `-m`: a message this size blows past
    # Windows' ~32KB command-line limit, and the resulting E2BIG silently
    # collapses the fixture to a single small commit that no longer
    # reproduces anything (found the hard way while writing this test).
    # Bulk generated with awk, NOT `yes ... | head -n N` (codex round 1 on
    # HIMMEL-1115): `yes | head` is itself a SIGPIPE-on-early-exit pipeline,
    # which is a poor thing to lean on inside a `pipefail` script whose whole
    # subject is that exact hazard. It happens to be harmless today (this
    # suite sets `-uo pipefail`, NOT `-e`, so a 141 pipeline status aborts
    # nothing), but it would break silently the day someone adds `set -e`.
    # awk emits the bulk in ONE process with no pipeline at all, so there is
    # no writer for anything to SIGPIPE.
    {
        echo "feat: bulky earlier commit"
        echo
        awk 'BEGIN { for (i = 0; i < 4000; i++) print "padding line for pipe-buffer bulk" }'
    } > "$d/.bulkmsg"
    git -c commit.gpgsign=false commit -q -F "$d/.bulkmsg"
    rm -f "$d/.bulkmsg"
    echo y >> scripts/foo.sh
    git add -A
    # NEWEST commit carries the attestation => grep -q matches almost
    # immediately, leaving ~88KB unread behind it.
    git -c commit.gpgsign=false commit -q -m "feat: attested change

Platforms tested: linux, windows"
) >/dev/null 2>&1
fixture_rc=$?
# Do NOT trust that subshell. Its exit status was discarded, and a silently-
# failed setup step (notably the bulk `commit -F "$d/.bulkmsg"` blowing past
# Windows' ~32KB argv limit -> E2BIG) collapses the range to a single small
# commit that the FIXED hook passes trivially. The test would then report
# GREEN while proving nothing (a first draft of this fixture did exactly
# that — see the bulkmsg notes above). The test's whole reason to exist is
# to exercise the >64KB SIGPIPE path, so PROVE the range was actually built
# before asserting a hook verdict on it.
if [ "$fixture_rc" -ne 0 ]; then
    echo "FAIL HIMMEL-1115: >64KB fixture setup failed (rc=$fixture_rc); cannot assert on a broken fixture"
    FAILED=$((FAILED + 1))
else
    # `git log | wc -c` cannot SIGPIPE — wc reads to EOF and never exits
    # early — so it is safe here even though the suite's whole subject is
    # that exact hazard. BSD wc pads stdin counts with spaces;
    # $((range_bytes)) coerces to a clean integer for the compare.
    range_bytes=$(git -C "$d" log --format=%B main..HEAD | wc -c)
    if [ "$((range_bytes))" -le 65536 ]; then
        echo "FAIL HIMMEL-1115: >64KB range collapsed to $((range_bytes)) bytes (<= 65536); SIGPIPE path NOT exercised"
        FAILED=$((FAILED + 1))
    else
        assert_rc "HIMMEL-1115: >64KB range, attestation in newest commit" 0 "$(run_in "$d")"
    fi
fi
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

# --- HIMMEL-323 item 1: fail-CLOSED on an unresolvable diff base ---
# A repo with NO main/master ref and NO remote: default_branch falls back to
# "main", which doesn't exist, so no diff base resolves. ONLINE (no *_NO_FETCH)
# this is a genuinely-broken state -> fail CLOSED (exit 2). With NO_FETCH the
# operator opted into offline mode -> skip (exit 0) with a loud warning, so
# offline/shallow workflows are preserved.
make_no_default_repo() {
    local files="$1" msg="$2" dir
    dir=$(mktemp -d)
    (
        cd "$dir" || exit 1
        git init -q -b feat/x   # HEAD on a feature branch; no main/master ref ever created
        git config user.email t@t
        git config user.name t
        # shellcheck disable=SC2086 # files is space-separated, intentional split
        for f in $files; do mkdir -p "$(dirname "$f")"; echo x > "$f"; done
        git add -A
        git -c commit.gpgsign=false commit -q -m "$msg"
    )
    echo "$dir"
}

d=$(make_no_default_repo "scripts/foo.sh" "feat: add foo")
assert_rc "unresolvable base, online -> fail CLOSED (exit 2)"         2 "$(run_in "$d")"
assert_rc "unresolvable base, NO_FETCH -> skip + warn (exit 0)"       0 "$(run_in "$d" "PLATFORMS_TESTED_NO_FETCH=1")"
rm -rf "$d"

# --- HIMMEL-323 item 2: branch resolved via lib.sh::_branch (worktree-correct) ---
# Non-git dir: _branch returns rc=2 -> hook fails CLOSED (exit 2) with a clear
# diagnostic, rather than letting `set -e` abort on git's opaque exit 128.
ngd=$(mktemp -d)
assert_rc "non-git dir -> rc=2 fail-closed (cannot read branch)"     2 "$(run_in "$ngd")"
rm -rf "$ngd"

# Pin that the gate FIRES from a LINKED worktree on a feature branch while the
# PRIMARY checkout sits on main: under the natural pre-push env (git points
# GIT_DIR at the worktree's own gitdir) the gate must read the worktree branch
# (feat/x), see the sensitive .sh, and BLOCK — never read the primary's 'main'
# and skip. Pins worktree-correct behaviour so future branch-resolution changes
# can't silently regress it.
origin=$(mktemp -d); base=$(mktemp -d)
( cd "$origin" || exit 1; git init -q --bare -b main ) >/dev/null 2>&1
(
    cd "$base" || exit 1
    git clone -q "$origin" . >/dev/null 2>&1
    git config user.email t@t
    git config user.name t
    echo r > README.md; git add -A; git -c commit.gpgsign=false commit -q -m init
    git push -q origin main >/dev/null 2>&1
    git worktree add -q -b feat/x "${base}-wt" >/dev/null 2>&1
    mkdir -p "${base}-wt/scripts"; echo 'echo hi' > "${base}-wt/scripts/new.sh"
    git -C "${base}-wt" add -A
    git -C "${base}-wt" -c commit.gpgsign=false commit -q -m "feat: shell, no attestation"
) >/dev/null 2>&1
wtgd="${base}/.git/worktrees/$(basename "${base}-wt")"
rc_wt=$( cd "${base}-wt" && env GIT_DIR="$wtgd" PLATFORMS_TESTED_NO_FETCH=1 bash "$HOOK" >/dev/null 2>&1; echo $? )
assert_rc "linked worktree (primary on main): reads worktree branch + blocks" 1 "$rc_wt"
git -C "$base" worktree remove --force "${base}-wt" >/dev/null 2>&1 || true
rm -rf "$origin" "$base" "${base}-wt"

# --- HIMMEL-323 item 1 (CR follow-up): fail-CLOSED when the diff itself errors ---
# An orphan/unrelated-history branch has no merge base, so `git diff base...HEAD`
# exits non-zero. The old `|| true` swallowed that to an empty changed-set -> a
# silent PASS on a branch never inspected. Now it fails CLOSED (exit 2).
d=$(mktemp -d)
(
    cd "$d" || exit 1
    git init -q -b main
    git config user.email t@t
    git config user.name t
    echo r > README.md; git add -A; git -c commit.gpgsign=false commit -q -m init
    git checkout -q --orphan feat/x
    git rm -rfq . 2>/dev/null || true
    mkdir -p scripts; echo 'echo x' > scripts/foo.sh
    git add -A; git -c commit.gpgsign=false commit -q -m "feat: orphan sensitive"
) >/dev/null 2>&1
assert_rc "orphan branch (no merge base) -> fail CLOSED (exit 2)"    2 "$(run_in "$d" "PLATFORMS_TESTED_NO_FETCH=1")"
rm -rf "$d"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
