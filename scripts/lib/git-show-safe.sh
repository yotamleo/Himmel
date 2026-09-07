#!/usr/bin/env bash
# scripts/lib/git-show-safe.sh — MSYS-safe `git show <ref>:<path>` (HIMMEL-2320).
#
# On Git Bash, `ref:path` gets MSYS path-converted into `ref;path` (or a
# mangled Windows path) unless MSYS_NO_PATHCONV=1 is set — git then fails
# with an unrelated "fatal: Path ... does not exist" on stderr, and a
# downstream `grep -c` on the resulting empty stdout silently counts 0,
# indistinguishable from a genuine miss (the HIMMEL-2320 judge/console
# incident). Sourced, not run.
#
# git_show_safe <ref> <path> — prints the blob to stdout on success. On
# failure, prints git's own stderr to the caller's stderr and returns git's
# rc — never lets a downstream command see empty stdin without a visible
# reason. Text-blob use only: command substitution strips trailing newlines
# and NUL bytes, so a blob with none/multiple trailing newlines or embedded
# NULs is not byte-faithful — fine for the ref:path config/script reads this
# is for, not for binary blobs.
git_show_safe() {
    local ref="$1" path="$2" out rc errfile
    # stderr goes to its own temp file, never merged into $out: git can print
    # a warning (e.g. an ambiguous-ref notice) to stderr alongside rc=0, and
    # 2>&1 would silently splice that warning into the returned blob content.
    errfile=$(mktemp "${TMPDIR:-/tmp}/git-show-safe.XXXXXX") || return 1
    # The assignment runs inside an `if` condition, not bare: under a
    # caller's `set -e`, a bare `out=$(git show ...)` would abort the
    # caller right here on a nonzero rc — before rc is captured, stderr is
    # reported, or errfile is cleaned up. A checked condition is exempt.
    if out=$(MSYS_NO_PATHCONV=1 git show "${ref}:${path}" 2>"$errfile"); then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        echo "git_show_safe: git show '${ref}:${path}' failed (rc=$rc):" >&2
        cat "$errfile" >&2
        rm -f "$errfile"
        return "$rc"
    fi
    rm -f "$errfile"
    printf '%s\n' "$out"
    return 0
}
