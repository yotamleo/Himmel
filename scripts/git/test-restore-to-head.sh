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
TMP="$(mktemp -d -t restore-to-head-test.XXXXXX)" || { echo "test-restore-to-head: mktemp failed" >&2; exit 2; }
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
    echo "test-restore-to-head: mktemp produced no usable directory" >&2
    exit 2
fi
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

PRIMARY="$TMP/primary"
WT="$TMP/wt"
BACKUPS="$TMP/backups"
mkdir -p "$PRIMARY" "$BACKUPS"
(
    cd "$PRIMARY" || exit 2
    git init -q -b main .
    git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
    printf 'base\n' > tracked.txt
    printf 'base2\n' > tracked2.txt
    mkdir -p sub
    printf '#!/bin/sh\necho hi\n' > sub/a.sh
    printf '#!/bin/sh\necho bye\n' > sub/b.sh
    mkdir -p other
    printf '#!/bin/sh\necho other\n' > other/a.sh
    printf 'base3\n' > tracked3.txt
    printf '\000\001\002binbase\n' > bin.dat
    git add tracked.txt tracked2.txt tracked3.txt sub/a.sh sub/b.sh other/a.sh bin.dat
    git commit -qm base
    git worktree add -q -b work "$WT" main
) || { echo "test-restore-to-head: repo setup failed" >&2; exit 2; }

# --- (h) documented RED control: the deny pattern matches a LEG's command
# line, not this script's own internal call. Assert the actual checkout
# invocation is present as EXECUTABLE code (not merely mentioned in a
# comment, which the header itself does for documentation purposes).
if [ -f "$SUT" ]; then
    if grep -v '^[[:space:]]*#' "$SUT" | grep -q 'checkout HEAD -- '; then
        pass "(h) script carries the internal checkout call as executable code, not just a comment"
    else
        fail "(h) script does not contain the expected internal checkout call outside of comments"
    fi
else
    fail "(h) $SUT does not exist yet"
fi

run() { (cd "$WT" && TMPDIR="$BACKUPS" bash "$SUT" "$@"); }

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
before_count=$(find "$BACKUPS/restore-to-head" -name '*.patch' 2>/dev/null | wc -l | tr -d ' ')
out=$(run tracked.txt); rc=$?
after_count=$(find "$BACKUPS/restore-to-head" -name '*.patch' 2>/dev/null | wc -l | tr -d ' ')
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

# --- (i) backup write failure must NOT be followed by a discard (codex-1).
# TMPDIR points at a plain FILE, not a directory, so creating the backup dir
# under it fails deterministically (ENOTDIR) regardless of user or platform
# permission semantics (chmod 555 is unreliable as root / under Git Bash --
# round-3 codex-5).
RO="$TMP/ro-file"
: > "$RO"
printf 'dirty\n' > "$WT/tracked.txt"
out=$(cd "$WT" && TMPDIR="$RO" bash "$SUT" tracked.txt 2>&1); rc=$?
content=$(cat "$WT/tracked.txt")
if [ "$rc" -ne 0 ] && [ "$content" = "dirty" ]; then
    pass "(i) unwritable backup dir aborts before discarding the dirty file"
else
    fail "(i) rc=$rc content='$content' (expected refusal, file left dirty -- backup dir was unwritable)"
fi
reset_wt

# --- (j) same basename in different directories -> distinct, non-colliding backups (codex-2)
printf 'dirty-sub\n' > "$WT/sub/a.sh"
printf 'dirty-other\n' > "$WT/other/a.sh"
out=$(run sub/a.sh other/a.sh); rc=$?
patches=$(printf '%s\n' "$out" | grep -o '/[^ ]*\.patch')
n_unique=$(printf '%s\n' "$patches" | sort -u | wc -l | tr -d ' ')
ok_sub=0; ok_other=0
for p in $patches; do
    grep -q 'dirty-sub' "$p" 2>/dev/null && ok_sub=1
    grep -q 'dirty-other' "$p" 2>/dev/null && ok_other=1
done
if [ "$rc" -eq 0 ] && [ "$n_unique" -eq 2 ] && [ "$ok_sub" -eq 1 ] && [ "$ok_other" -eq 1 ]; then
    pass "(j) same-basename files in different dirs get distinct, non-colliding backups"
else
    fail "(j) rc=$rc n_unique=$n_unique ok_sub=$ok_sub ok_other=$ok_other out='$out'"
fi
reset_wt

# --- (k) binary file diff is actually recoverable via the saved patch (codex-3)
printf '\000\001\002bindirty\n' > "$WT/bin.dat"
out=$(run bin.dat); rc=$?
patch_path=$(printf '%s\n' "$out" | grep -o '/[^ ]*\.patch' | head -1)
recon="$TMP/recon"
rm -rf "$recon"; mkdir -p "$recon"
(cd "$recon" && git init -q -b main . && git config user.email t@t.t && git config user.name t && git config commit.gpgsign false && cp "$PRIMARY/bin.dat" . && git add bin.dat && git commit -qm base && git apply "$patch_path" && cmp -s bin.dat <(printf '\000\001\002bindirty\n'))
recon_rc=$?
if [ "$rc" -eq 0 ] && [ -n "$patch_path" ] && [ "$recon_rc" -eq 0 ]; then
    pass "(k) binary file's saved patch reconstructs the dirty content exactly"
else
    fail "(k) rc=$rc patch_path='$patch_path' recon_rc=$recon_rc (binary diff not recoverable)"
fi
reset_wt

# --- (l) a staged-only change (index != HEAD) is restored to HEAD, not left at index (codex-4)
(cd "$WT" && printf 'staged-only\n' > tracked.txt && git add tracked.txt)
out=$(run tracked.txt); rc=$?
content=$(cat "$WT/tracked.txt")
if [ "$rc" -eq 0 ] && [ "$content" = "base" ]; then
    pass "(l) staged-only change restored all the way to HEAD"
else
    fail "(l) rc=$rc content='$content' (expected HEAD content 'base', script only compares to the index)"
fi
reset_wt
(cd "$WT" && git reset -q --hard main)

# --- (m) invocation from a subdirectory resolves paths correctly (codex-5)
printf 'dirty-from-sub\n' > "$WT/sub/a.sh"
out=$(cd "$WT/sub" && TMPDIR="$BACKUPS" bash "$SUT" a.sh 2>&1); rc=$?
content=$(cat "$WT/sub/a.sh")
if [ "$rc" -eq 0 ] && [ "$content" != "dirty-from-sub" ]; then
    pass "(m) invocation from a subdirectory correctly restores the file"
else
    fail "(m) rc=$rc content='$content' (expected restore to succeed when invoked from inside a subdirectory)"
fi
reset_wt

# --- (n) a magic pathspec argument cannot bypass the directory refusal (round-2 codex-3)
printf 'dirty-sub-a\n' > "$WT/sub/a.sh"
printf 'dirty-sub-b\n' > "$WT/sub/b.sh"
run ':(top)sub' >/dev/null 2>&1; rc=$?
content_a=$(cat "$WT/sub/a.sh")
content_b=$(cat "$WT/sub/b.sh")
if [ "$rc" -ne 0 ] && [ "$content_a" = "dirty-sub-a" ] && [ "$content_b" = "dirty-sub-b" ]; then
    pass "(n) magic-pathspec argument refused, directory contents untouched"
else
    fail "(n) rc=$rc content_a='$content_a' content_b='$content_b' (expected refusal, both files still dirty)"
fi
reset_wt

# --- (o) an unborn repository (no HEAD yet) is refused, not silently a no-op (round-2 codex-4)
UNBORN="$TMP/unborn"
mkdir -p "$UNBORN"
(cd "$UNBORN" && git init -q -b main . && git config user.email t@t.t && git config user.name t && git config commit.gpgsign false && printf 'x\n' > f.txt && git add f.txt)
out=$(cd "$UNBORN" && TMPDIR="$BACKUPS" bash "$SUT" f.txt 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'HEAD'; then
    pass "(o) unborn repository is refused with a clear error, not a silent no-op"
else
    fail "(o) rc=$rc out='$out' (expected refusal naming the missing HEAD)"
fi

# --- (p) staged content that differs from the worktree is backed up too, not silently discarded (round-2 codex-2)
(cd "$WT" && printf 'staged-mid\n' > tracked.txt && git add tracked.txt && printf 'worktree-final\n' > tracked.txt)
out=$(run tracked.txt 2>&1); rc=$?
content=$(cat "$WT/tracked.txt")
staged_blob_path=$(printf '%s\n' "$out" | grep -o '/[^ ]*\.staged-blob' | head -1)
if [ "$rc" -eq 0 ] && [ "$content" = "base" ] && [ -n "$staged_blob_path" ] && [ -f "$staged_blob_path" ] && [ "$(cat "$staged_blob_path")" = "staged-mid" ]; then
    pass "(p) staged content differing from the worktree is separately backed up before the discard"
else
    fail "(p) rc=$rc content='$content' staged_blob_path='$staged_blob_path' (expected the staged 'staged-mid' content recoverable, not silently lost)"
fi
reset_wt
(cd "$WT" && git reset -q --hard main)

# --- (q) index differs from HEAD even though the worktree already matches HEAD
# is still detected and restored, not silently skipped as a no-op (round-3 codex-1)
(cd "$WT" && printf 'staged-then-reverted\n' > tracked.txt && git add tracked.txt && printf 'base\n' > tracked.txt)
out=$(run tracked.txt 2>&1); rc=$?
final_idx_diff=$(cd "$WT" && git diff --cached --stat HEAD -- tracked.txt)
content=$(cat "$WT/tracked.txt")
if [ "$rc" -eq 0 ] && [ -z "$final_idx_diff" ] && [ "$content" = "base" ]; then
    pass "(q) staged content is restored to HEAD even when the worktree already matched HEAD"
else
    fail "(q) rc=$rc final_idx_diff='$final_idx_diff' content='$content' (expected the index restored to HEAD, not left dirty)"
fi
reset_wt
(cd "$WT" && git reset -q --hard main)

# --- (r) backup run directory is private (mktemp, not a predictable shared
# /tmp path another local user could pre-create or symlink) (round-3 codex-2)
printf 'dirty\n' > "$WT/tracked.txt"
out=$(run tracked.txt); rc=$?
patch_path=$(printf '%s\n' "$out" | grep -o '/[^ ]*\.patch' | head -1)
run_dir=$(dirname "$patch_path")
mode=$(stat -c '%a' "$run_dir" 2>/dev/null || stat -f '%Lp' "$run_dir" 2>/dev/null)
if [ "$rc" -eq 0 ] && [ "$mode" = "700" ]; then
    pass "(r) backup run directory is a private mktemp directory (mode 700)"
else
    fail "(r) rc=$rc run_dir='$run_dir' mode='$mode' (expected a private mktemp-created directory, mode 700)"
fi
reset_wt

echo "---"
if [ "$FAILED" -gt 0 ]; then
    echo "test-restore-to-head: $FAILED FAILURE(S)"
    exit 1
fi
echo "test-restore-to-head: all cases pass"
