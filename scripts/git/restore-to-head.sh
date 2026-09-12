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

git -C "$TOPLEVEL" rev-parse --verify -q HEAD >/dev/null 2>&1 || {
    echo "restore-to-head: HEAD does not exist yet (unborn repository) -- nothing to restore to" >&2; exit 2; }

for arg in "$@"; do
    case "$arg" in
        *'*'*|*'?'*|*'['*) echo "restore-to-head: refusing glob argument '$arg'" >&2; exit 2 ;;
        .|..|*/) echo "restore-to-head: refusing '$arg'" >&2; exit 2 ;;
        :*) echo "restore-to-head: refusing magic-pathspec argument '$arg'" >&2; exit 2 ;;
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
    git -C "$TOPLEVEL" ls-files --error-unmatch -- ":(literal)$rel" >/dev/null 2>&1 || {
        echo "restore-to-head: '$arg' is untracked -- refusing (never rm)" >&2; exit 2; }
    RELS+=("$rel")
done

SAVE_DIR="${TMPDIR:-/tmp}/restore-to-head"
RUN_DIR="$SAVE_DIR/$(date +%s)-$$"
mkdir -p "$RUN_DIR"

for rel in "${RELS[@]}"; do
    if [ -n "$(git -C "$TOPLEVEL" diff --binary HEAD -- ":(literal)$rel")" ]; then
        patch="$RUN_DIR/$rel.patch"
        mkdir -p "$(dirname "$patch")"
        if ! git -C "$TOPLEVEL" diff --binary HEAD -- ":(literal)$rel" > "$patch" || [ ! -s "$patch" ]; then
            echo "restore-to-head: could not write backup for '$rel' to '$patch' -- aborting without discarding it" >&2
            exit 2
        fi
        if [ -n "$(git -C "$TOPLEVEL" diff --binary -- ":(literal)$rel")" ] \
            && [ -n "$(git -C "$TOPLEVEL" diff --binary --cached HEAD -- ":(literal)$rel")" ]; then
            staged_blob="$RUN_DIR/$rel.staged-blob"
            if ! git -C "$TOPLEVEL" show ":$rel" > "$staged_blob" 2>/dev/null || [ ! -s "$staged_blob" ]; then
                echo "restore-to-head: could not back up staged index content for '$rel' -- aborting without discarding it" >&2
                exit 2
            fi
            echo "restore-to-head: '$rel' also has staged content that differs from the worktree (saved separately: $staged_blob)" >&2
        fi
        git -C "$TOPLEVEL" checkout HEAD -- ":(literal)$rel"
        echo "restored $rel (saved diff: $patch)"
    else
        echo "restore-to-head: '$rel' already matches HEAD -- no-op"
    fi
done

for rel in "${RELS[@]}"; do
    remaining=$(git -C "$TOPLEVEL" diff --stat HEAD -- ":(literal)$rel") || {
        echo "restore-to-head: could not verify '$rel' is clean after restore" >&2; exit 2; }
    [ -z "$remaining" ] || { echo "restore-to-head: '$rel' still differs from HEAD after restore" >&2; exit 2; }
done
