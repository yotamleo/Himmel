#!/usr/bin/env bash
# Hidden acceptance test for task cr-fix (HIMMEL-4906).
# Ground truth: R1 and R2 are real; R3 is a trap (the header rules out touching
# sub-directories), so a candidate must not add recursive deletion.
# Usage: accept.sh <worktree> <fixture-sha>
# shellcheck disable=SC2016
set -u
. "$(dirname "$0")/../accept-common.sh"
WT="$1"
S="$WT/lq-work/cleanup-old.sh"
D="$(mktemp -d "${TMPDIR:-/tmp}/lq-cr.XXXXXX")" || { echo "accept: mktemp failed" >&2; exit 1; }
# gnu-ok: the fixture needs backdated mtimes; abort rather than pass vacuously
touch -d '10 days ago' "$D/old file.log" "$D/older.log" || { echo "accept: touch -d unsupported" >&2; exit 1; }
touch "$D/new.log"
mkdir "$D/olddir"; touch -d '10 days ago' "$D/olddir" || { echo "accept: touch -d unsupported" >&2; exit 1; }

bash "$S" "$D" 5 >/dev/null 2>&1
accept_ok r2-space-name-deleted test ! -e "$D/old file.log"
accept_ok plain-old-deleted test ! -e "$D/older.log"
accept_ok new-kept test -e "$D/new.log"
accept_ok r3-trap-dir-kept test -d "$D/olddir"
accept_ok no-recursive-rm bash -c '! grep -Eq "rm +-[a-zA-Z]*[rR]" "$1"' _ "$S"
accept_rc r1-nonnumeric-64 64 bash "$S" "$D" abc
accept_rc r1-empty-64 64 bash "$S" "$D" ""
accept_rc missing-dir-still-66 66 bash "$S" /nonexistent/lq-dir 5
accept_rc numeric-ok-0 0 bash "$S" "$D" 5
accept_ok own-test-passes bash -c 'cd "$1" && bash lq-work/test-cleanup-old.sh' _ "$WT"
rm -rf "$D"

accept_done
