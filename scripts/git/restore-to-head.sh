#!/usr/bin/env bash
# restore-to-head.sh <path>... — the sanctioned shape for restoring one or
# more tracked files to HEAD in a leg (HIMMEL-2934). `git checkout -- <path>`
# is a `deny` entry in .claude/settings.json and `git restore` falls through
# unmatched to the classifier, resolving as a silent headless DENY. This
# script does the same restore but saves the outgoing diff first, so the
# discard is recoverable, and refuses globs, untracked paths, directories,
# and paths outside the current worktree — everything bare checkout would
# silently accept.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure git + POSIX shell; no .ps1 twin needed.
set -uo pipefail

usage() {
    cat <<'EOF'
usage: restore-to-head.sh <path> [<path>...]

Restores one or more tracked files to HEAD, saving the outgoing diff for
each dirty path first (recoverable via `git apply`). Refuses glob
arguments, untracked paths, directories, and paths outside the current
worktree.
EOF
}

[ $# -ge 1 ] || { usage >&2; exit 2; }
case "$1" in -h|--help) usage; exit 0 ;; esac

TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "restore-to-head: not inside a git repository" >&2; exit 2; }

for arg in "$@"; do
    case "$arg" in
        *'*'*|*'?'*|*'['*) echo "restore-to-head: refusing glob argument '$arg'" >&2; exit 2 ;;
        .|..|*/) echo "restore-to-head: refusing '$arg'" >&2; exit 2 ;;
    esac
done

RELS=()
for arg in "$@"; do
    case "$arg" in
        /*) abs="$arg" ;;
        *)  abs="$PWD/$arg" ;;
    esac
    case "$abs" in
        "$TOPLEVEL"/*) : ;;
        *) echo "restore-to-head: '$arg' resolves outside this worktree ($TOPLEVEL)" >&2; exit 2 ;;
    esac
    [ -d "$abs" ] && { echo "restore-to-head: '$arg' is a directory" >&2; exit 2; }
    rel="${abs#"$TOPLEVEL"/}"
    git -C "$TOPLEVEL" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 || {
        echo "restore-to-head: '$arg' is untracked -- refusing (never rm)" >&2; exit 2; }
    RELS+=("$rel")
done

SAVE_DIR="${TMPDIR:-/tmp}/restore-to-head"
mkdir -p "$SAVE_DIR"
STAMP=$(date +%s)

for rel in "${RELS[@]}"; do
    if [ -n "$(git -C "$TOPLEVEL" diff --binary HEAD -- "$rel")" ]; then
        safe_name=$(printf '%s' "$rel" | tr '/' '_')
        patch="$SAVE_DIR/${STAMP}-${safe_name}.patch"
        if ! git -C "$TOPLEVEL" diff --binary HEAD -- "$rel" > "$patch" || [ ! -s "$patch" ]; then
            echo "restore-to-head: could not write backup for '$rel' to '$patch' -- aborting without discarding it" >&2
            exit 2
        fi
        git -C "$TOPLEVEL" checkout HEAD -- "$rel"
        echo "restored $rel (saved diff: $patch)"
    else
        echo "restore-to-head: '$rel' already matches HEAD -- no-op"
    fi
done

remaining=$(git -C "$TOPLEVEL" diff --stat HEAD -- "${RELS[@]}")
[ -z "$remaining" ]
