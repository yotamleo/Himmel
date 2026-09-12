#!/usr/bin/env bash
# restore-to-head.sh <path>... — the sanctioned shape for restoring one or
# more tracked files to HEAD in a leg (HIMMEL-2934). `git checkout -- <path>`
# is a `deny` entry in .claude/settings.json and `git restore` falls through
# unmatched to the classifier, resolving as a silent headless DENY. This
# script does the same restore but saves the outgoing content first, so the
# discard is recoverable, and refuses globs, untracked paths, directories,
# and paths outside the current worktree — everything bare checkout would
# silently accept.
#
# Backups are PLAIN COPIES, not diffs: a per-file worktree copy (`cp -p`,
# mode preserved) and, when the index differs from HEAD, the staged blob
# (`git show`) plus its `git ls-files -s` mode line. A diff/patch-based
# backup depends on git actually being able to reproduce and re-apply a
# patch — a configured external-diff/textconv driver can make `git diff`
# emit nonempty, non-applicable output, and a unified diff cannot carry an
# index-only mode or type change at all. A plain copy has neither failure
# mode: recovery is `cp` back, which no diff driver, binary content or mode
# bit can defeat (HIMMEL-2934 round 5, codex-1/codex-4).
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure git + POSIX shell; no .ps1 twin needed.
set -uo pipefail

usage() {
    cat <<'EOF'
usage: restore-to-head.sh <path> [<path>...]

Restores one or more tracked files to HEAD, saving a plain copy of each
dirty path's worktree content and staged index content first (recoverable
via `cp` / `git show`). Refuses glob arguments, untracked paths,
directories, and paths outside the current worktree.
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

RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/restore-to-head.XXXXXX") || {
    echo "restore-to-head: could not create a private backup directory under ${TMPDIR:-/tmp}" >&2
    exit 2
}
MANIFEST="$RUN_DIR/MANIFEST"
: > "$MANIFEST"

n=0
for rel in "${RELS[@]}"; do
    n=$((n + 1))

    wt_differs=1
    git -C "$TOPLEVEL" diff --no-ext-diff --no-textconv --quiet HEAD -- ":(literal)$rel" && wt_differs=0
    idx_differs=1
    git -C "$TOPLEVEL" diff --no-ext-diff --no-textconv --quiet --cached HEAD -- ":(literal)$rel" && idx_differs=0

    if [ "$wt_differs" -eq 0 ] && [ "$idx_differs" -eq 0 ]; then
        echo "restore-to-head: '$rel' already matches HEAD -- no-op"
        continue
    fi

    echo "$n $rel" >> "$MANIFEST"

    saved_wt=""
    if [ "$wt_differs" -eq 1 ]; then
        saved_wt="$RUN_DIR/$n.worktree"
        if ! cp -p "$TOPLEVEL/$rel" "$saved_wt"; then
            echo "restore-to-head: could not back up worktree content for '$rel' to '$saved_wt' -- aborting without discarding it" >&2
            exit 2
        fi
    fi

    saved_idx=""
    if [ "$idx_differs" -eq 1 ]; then
        saved_idx="$RUN_DIR/$n.index"
        if ! git -C "$TOPLEVEL" show ":$rel" > "$saved_idx" 2>/dev/null; then
            echo "restore-to-head: could not back up staged index content for '$rel' -- aborting without discarding it" >&2
            exit 2
        fi
        if ! git -C "$TOPLEVEL" ls-files -s -- ":(literal)$rel" > "$RUN_DIR/$n.index-mode"; then
            echo "restore-to-head: could not back up staged index mode for '$rel' -- aborting without discarding it" >&2
            exit 2
        fi
        echo "restore-to-head: '$rel' has staged content that differs from HEAD (saved separately: $saved_idx)" >&2
    fi

    git -C "$TOPLEVEL" checkout HEAD -- ":(literal)$rel"
    if [ -n "$saved_wt" ]; then
        echo "restored $rel (saved worktree copy: $saved_wt)"
    else
        echo "restored $rel (staged-only change; saved separately: $saved_idx)"
    fi
done

for rel in "${RELS[@]}"; do
    remaining_wt=$(git -C "$TOPLEVEL" diff --no-ext-diff --no-textconv --stat HEAD -- ":(literal)$rel") || {
        echo "restore-to-head: could not verify '$rel' is clean after restore" >&2; exit 2; }
    remaining_idx=$(git -C "$TOPLEVEL" diff --no-ext-diff --no-textconv --cached --stat HEAD -- ":(literal)$rel") || {
        echo "restore-to-head: could not verify '$rel' index is clean after restore" >&2; exit 2; }
    if [ -n "$remaining_wt" ] || [ -n "$remaining_idx" ]; then
        echo "restore-to-head: '$rel' still differs from HEAD after restore" >&2; exit 2
    fi
done
