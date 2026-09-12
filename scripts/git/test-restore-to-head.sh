#!/usr/bin/env bash
# Hermetic tests for restore-to-head.sh (HIMMEL-2934).
#
# WHY THIS EXISTS: `git checkout -- <path>` is a settings.json `deny` entry
# (.claude/settings.json:108) and `git restore` falls through unmatched to
# the classifier, resolving as a silent headless DENY (HIMMEL-203). Neither
# is a sanctioned way for a leg to run the RED half of a TDD control (restore
# a tracked file to HEAD, run the suite, expect the predicted failure).
# restore-to-head.sh is the sanctioned shape: it does the same restore but
# saves the outgoing diff first, so the discard is recoverable, and it
# refuses everything bare checkout would silently accept (globs, untracked
# paths, paths outside the current worktree).
#
# Runs in a throwaway PRIMARY repo plus a linked WORKTREE built under
# mktemp -d, never the real repo, so it never touches real history.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure git + POSIX shell; no .ps1 twin needed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/restore-to-head.sh"
TMP="$(mktemp -d -t restore-to-head-test.XXXXXX)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

PRIMARY="$TMP/primary"
WT="$TMP/wt"
mkdir -p "$PRIMARY"
(
    cd "$PRIMARY" || exit 2
    git init -q -b main .
    git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
    printf 'base\n' > tracked.txt
    printf 'base2\n' > tracked2.txt
    mkdir -p sub
    printf '#!/bin/sh\necho hi\n' > sub/a.sh
    printf '#!/bin/sh\necho bye\n' > sub/b.sh
    git add tracked.txt tracked2.txt sub/a.sh sub/b.sh
    git commit -qm base
    git worktree add -q -b work "$WT" main
)

# --- (h) documented RED control: the deny pattern matches a LEG's command
# line, not this script's own internal call. Assert the script's internal
# invocation is present as source text (not something a caller types).
if [ -f "$SUT" ]; then
    if grep -q 'git checkout -- ' "$SUT"; then
        pass "(h) script carries the internal checkout call (deny matches the LEG's line, not this child process)"
    else
        fail "(h) script does not contain the expected internal 'git checkout -- ' call"
    fi
else
    fail "(h) $SUT does not exist yet"
fi

run() { (cd "$WT" && bash "$SUT" "$@"); }

reset_wt() { (cd "$WT" && git checkout -q main -- . 2>/dev/null; git clean -qfd 2>/dev/null); }

# --- (a) dirty one tracked file -> restored, recoverable via saved diff
printf 'dirty\n' > "$WT/tracked.txt"
out=$(run tracked.txt); rc=$?
stat_out=$(cd "$WT" && git diff --stat -- tracked.txt)
if [ "$rc" -eq 0 ] && [ -z "$stat_out" ]; then
    pass "(a) rc=0 and tree clean after restore"
else
    fail "(a) rc=$rc stat='$stat_out'"
fi
patch_path=$(printf '%s\n' "$out" | grep -o '/[^ ]*\.patch' | head -1)
if [ -n "$patch_path" ] && [ -f "$patch_path" ]; then
    if (cd "$WT" && git apply --check "$patch_path" 2>/dev/null); then
        pass "(a) saved diff applies cleanly (discard is recoverable)"
    else
        fail "(a) saved diff at $patch_path does not apply cleanly"
    fi
else
    fail "(a) no saved-diff path found in output: $out"
fi
reset_wt

# --- (b) two paths in one call -> both restored, one saved-diff each
printf 'dirty1\n' > "$WT/tracked.txt"
printf 'dirty2\n' > "$WT/tracked2.txt"
out=$(run tracked.txt tracked2.txt); rc=$?
stat_out=$(cd "$WT" && git diff --stat -- tracked.txt tracked2.txt)
n_patches=$(printf '%s\n' "$out" | grep -c '\.patch')
if [ "$rc" -eq 0 ] && [ -z "$stat_out" ] && [ "$n_patches" -eq 2 ]; then
    pass "(b) two paths both restored, one saved-diff each"
else
    fail "(b) rc=$rc stat='$stat_out' n_patches=$n_patches"
fi
reset_wt

# --- (c) a glob argument is refused, tree untouched
printf 'dirty\n' > "$WT/tracked.txt"
run '*.sh' >/dev/null 2>&1; rc=$?
stat_out=$(cd "$WT" && git diff --stat -- tracked.txt)
if [ "$rc" -ne 0 ] && [ -n "$stat_out" ]; then
    pass "(c) glob argument refused, tree untouched"
else
    fail "(c) rc=$rc stat='$stat_out' (expected refusal, tree still dirty)"
fi
run '.' >/dev/null 2>&1; rc_dot=$?
if [ "$rc_dot" -ne 0 ]; then
    pass "(c) '.' argument refused"
else
    fail "(c) '.' argument was NOT refused (rc=$rc_dot)"
fi
reset_wt

# --- (d) a path outside the current worktree is refused, tree untouched
printf 'dirty\n' > "$PRIMARY/tracked.txt"
run "$PRIMARY/tracked.txt" >/dev/null 2>&1; rc=$?
stat_out=$(cd "$PRIMARY" && git diff --stat -- tracked.txt)
if [ "$rc" -ne 0 ] && [ -n "$stat_out" ]; then
    pass "(d) path outside the worktree refused, tree untouched"
else
    fail "(d) rc=$rc stat='$stat_out' (expected refusal)"
fi
(cd "$PRIMARY" && git checkout -q -- tracked.txt)

# --- (e) an untracked path is refused, message names it untracked
printf 'new\n' > "$WT/untracked.txt"
out=$(run untracked.txt 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'untracked'; then
    pass "(e) untracked path refused, message names it untracked"
else
    fail "(e) rc=$rc out='$out' (expected refusal naming it untracked)"
fi
if [ -f "$WT/untracked.txt" ]; then
    pass "(e) untracked file was never removed"
else
    fail "(e) untracked file was deleted -- must never rm"
fi
rm -f "$WT/untracked.txt"

# --- (f) a clean tracked file is a no-op, says so, no saved-diff written
before_count=$(find "${TMPDIR:-/tmp}/restore-to-head" -name '*.patch' 2>/dev/null | wc -l | tr -d ' ')
out=$(run tracked.txt); rc=$?
after_count=$(find "${TMPDIR:-/tmp}/restore-to-head" -name '*.patch' 2>/dev/null | wc -l | tr -d ' ')
if [ "$rc" -eq 0 ] && [ "$before_count" -eq "$after_count" ]; then
    pass "(f) clean tracked file is a no-op, no saved-diff written"
else
    fail "(f) rc=$rc before=$before_count after=$after_count out='$out'"
fi

# --- (g) no arguments -> usage, rc != 0
out=$(run 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'usage'; then
    pass "(g) no arguments prints usage and exits non-zero"
else
    fail "(g) rc=$rc out='$out' (expected usage + non-zero)"
fi

echo "---"
if [ "$FAILED" -gt 0 ]; then
    echo "test-restore-to-head: $FAILED FAILURE(S)"
    exit 1
fi
echo "test-restore-to-head: all cases pass"
