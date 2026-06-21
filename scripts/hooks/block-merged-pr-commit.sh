#!/usr/bin/env bash
# PreToolUse hook: block-merged-pr-commit.sh
#
# Blocks a `git commit` onto a branch whose PR is already MERGED. This is a
# HYGIENE guard, not a security boundary — it must FAIL-OPEN everywhere except
# a positively confirmed merged-branch commit.
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 — allow (default for any non-blocking path; also: fail-open)
#   2 — block; stderr is shown to Claude and the user
#
# Bypass: MERGED_PR_COMMIT_OK=1 (set in the LAUNCHING shell, not per-call).
#
# HIMMEL-512
set -uo pipefail
# NOTE: NOT set -e — a fail-open hook must never abort on rc 1 from a sub-call.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Fail-open on missing deps ────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    # jq missing; cannot parse stdin — fail open (hygiene guard, not security).
    exit 0
fi

# ─── Bypass ───────────────────────────────────────────────────────────────────
if [ "${MERGED_PR_COMMIT_OK:-0}" = "1" ]; then
    exit 0
fi

# ─── Read stdin ───────────────────────────────────────────────────────────────
input=$(cat)

raw_cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
raw_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)

# If we cannot parse the command, fail open.
[ -z "$raw_cmd" ] && exit 0

# ─── Detect a git commit segment ─────────────────────────────────────────────
# Split the command on ; && || and newline (NOT |).
# For each segment: tokenise on whitespace, find a `git` token, consume an
# optional `-C <dir>` pair, then the NEXT token must be EXACTLY `commit`
# (not a prefix like commit-graph or commit-tree). A standalone `--dry-run`
# in the same segment → skip (read-only).

# We use a POSIX read-loop approach: replace ; && || \n with newlines, then
# iterate over lines (each is a segment candidate).
# Use printf + sed to normalise separators.  bash 3.2-safe: no mapfile.
# We escape the awk separators explicitly.

commit_segment=""   # the segment containing `git commit`
commit_dir_flag=""  # value from `git -C <dir>` if present in commit segment
_found_commit=0

# Normalise compound operators to newlines.  Use printf + tr/sed (portable).
normalised=$(printf '%s' "$raw_cmd" | \
    sed 's/&&/\n/g' | \
    sed 's/||/\n/g' | \
    sed 's/;/\n/g')

# IFS loop over lines — bash 3.2 compatible.
while IFS= read -r segment || [ -n "$segment" ]; do
    # Skip empty segments.
    [ -z "$(printf '%s' "$segment" | tr -d '[:space:]')" ] && continue

    # Tokenise the segment on whitespace.
    # Load tokens into positional parameters (bash 3.2-safe).
    # set -f prevents glob expansion of metacharacters (e.g. /path*) so that
    # a segment like `git -C /some/path* commit` does NOT expand the glob and
    # produce a real filesystem path that would pass _is_literal and false-block.
    # Word-splitting is still intentional (SC2086).
    set -f
    # shellcheck disable=SC2086
    set -- $segment
    set +f

    _has_git=0
    _captured_dir=""
    _is_commit=0
    _has_dry_run=0

    while [ $# -gt 0 ]; do
        tok="$1"; shift

        if [ "$_has_git" -eq 0 ]; then
            [ "$tok" = "git" ] && _has_git=1
            continue
        fi

        # We've seen `git`. Now look for optional -C <dir>.
        if [ "$tok" = "-C" ] && [ $# -gt 0 ]; then
            _captured_dir="$1"; shift
            continue
        fi

        # Next significant token after git [-C <dir>] must be exactly `commit`.
        if [ "$tok" = "commit" ]; then
            _is_commit=1
            # Scan remaining tokens for --dry-run.
            while [ $# -gt 0 ]; do
                [ "$1" = "--dry-run" ] && _has_dry_run=1
                shift
            done
        fi
        # Stop parsing after the verb (whether it's commit or something else).
        break
    done

    if [ "$_is_commit" -eq 1 ]; then
        if [ "$_has_dry_run" -eq 1 ]; then
            # Read-only — skip.
            _found_commit=0
        else
            _found_commit=1
            commit_segment="$segment"
            commit_dir_flag="$_captured_dir"
        fi
        break
    fi

done <<EOF
$normalised
EOF

[ "$_found_commit" -eq 0 ] && exit 0

# ─── Resolve the directory for the commit ────────────────────────────────────
# Strategy:
#  1. If `git -C <dir>` was present and <dir> is a literal (no $, `, *, (, )),
#     unexpanded ~) → use that dir (resolved relative to raw_cwd).
#  2. Otherwise track current_dir by walking segments BEFORE the commit segment,
#     applying literal `cd <target>` changes.
#  3. If dir is UNKNOWN at any point → exit 0 (fail-open).
#
# "Literal" means the token contains none of: $ ` * ( ) ~ (at start or mid).

_is_literal() {
    local tok="$1"
    case "$tok" in
        *'$'*|*'`'*|*'*'*|*'('*|*')'*|'~'*|*'~'*) return 1 ;;
    esac
    return 0
}

# Resolve a path relative to a base dir (both absolute already on POSIX, or
# absolute on Windows with /c/... MINGW paths).
# Returns empty if resolution fails.
_resolve_path() {
    local base="$1" target="$2"
    # If target is absolute (starts with / or a drive letter like /c/ on MINGW),
    # use it directly.
    case "$target" in
        /*) printf '%s' "$target" ;;
        [A-Za-z]:/*) printf '%s' "$target" ;;
        [A-Za-z]:*) printf '%s' "$target" ;;
        *) printf '%s/%s' "$base" "$target" ;;
    esac
}

commit_dir=""

if [ -n "$commit_dir_flag" ]; then
    if _is_literal "$commit_dir_flag"; then
        commit_dir=$(_resolve_path "${raw_cwd:-/}" "$commit_dir_flag")
    else
        # Non-literal -C arg — fail open.
        exit 0
    fi
else
    # No -C flag; walk segments before the commit segment to track `cd`.
    current_dir="${raw_cwd:-}"
    dir_unknown=0

    while IFS= read -r seg || [ -n "$seg" ]; do
        [ -z "$(printf '%s' "$seg" | tr -d '[:space:]')" ] && continue

        # Stop when we reach the commit segment.
        if [ "$seg" = "$commit_segment" ]; then
            break
        fi

        # Detect `cd <target>` in this segment.
        # IMPORTANT: extract the cd target from the RAW segment text BEFORE any
        # shell expansion. Using `set -- $seg` would expand variables like
        # $EVIL_REPO to real paths before _is_literal sees them, causing a
        # false-block (exit 2) on commands like `cd $VAR && git commit`.
        # We parse the raw string directly with sed/case instead.
        raw_seg_trimmed=$(printf '%s' "$seg" | sed 's/^[[:space:]]*//')
        case "$raw_seg_trimmed" in
            cd[[:space:]]*)
                # Extract everything after "cd " (raw, unexpanded).
                raw_cd_remainder=$(printf '%s' "$raw_seg_trimmed" | sed 's/^cd[[:space:]]*//')
                # Trim trailing whitespace.
                raw_cd_remainder=$(printf '%s' "$raw_cd_remainder" | sed 's/[[:space:]]*$//')
                if [ -z "$raw_cd_remainder" ]; then
                    # `cd ` with no target — unknown.
                    dir_unknown=1
                elif printf '%s' "$raw_cd_remainder" | grep -q '[[:space:]]'; then
                    # Multiple tokens after cd (e.g. `cd /a /b`) — unknown.
                    dir_unknown=1
                elif _is_literal "$raw_cd_remainder"; then
                    current_dir=$(_resolve_path "$current_dir" "$raw_cd_remainder")
                else
                    # Contains $ ` * ( ) ~ — non-literal → unknown, fail open.
                    dir_unknown=1
                fi
                ;;
            cd)
                # `cd` with no argument — unknown (would go to $HOME).
                dir_unknown=1
                ;;
        esac
    done <<EOF2
$normalised
EOF2

    if [ "$dir_unknown" -eq 1 ]; then
        exit 0
    fi

    commit_dir="$current_dir"
fi

# If commit_dir is still empty, fall back to raw_cwd.
[ -z "$commit_dir" ] && commit_dir="${raw_cwd:-}"
[ -z "$commit_dir" ] && exit 0

# ─── Resolve branch and primary worktree ─────────────────────────────────────
branch=""
branch=$(git -C "$commit_dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""

# Failure or detached HEAD → fail open.
[ -z "$branch" ] && exit 0
[ "$branch" = "HEAD" ] && exit 0

# Compute the primary worktree dir: git --git-common-dir → its parent.
git_common_dir=""
git_common_dir=$(git -C "$commit_dir" rev-parse --git-common-dir 2>/dev/null) || git_common_dir=""
[ -z "$git_common_dir" ] && exit 0

# Resolve to absolute path (git may return relative).
case "$git_common_dir" in
    /*) primary=$(dirname "$git_common_dir") ;;
    [A-Za-z]:*) primary=$(dirname "$git_common_dir") ;;
    *) primary=$(dirname "$commit_dir/$git_common_dir") ;;
esac

# ─── Source branch-shipped.sh and call the predicate ─────────────────────────
# shellcheck source=../lib/branch-shipped.sh
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../lib/branch-shipped.sh" 2>/dev/null; then
    # Cannot source the lib — fail open (hygiene guard).
    exit 0
fi

bhmpr_rc=0
branch_has_merged_pr "$branch" "$primary" || bhmpr_rc=$?

case "$bhmpr_rc" in
    0)
        # Positively merged — BLOCK.
        cat >&2 <<EOF
⛔ block-merged-pr-commit: refusing to commit onto branch '$branch' — its PR is
already MERGED. Committing onto a shipped branch accumulates unreachable work.

Start fresh work in a new worktree instead:

    /worktree feat/<new-scope>          # create an isolated worktree
    /clean_garden feat/<new-scope>      # prune merged + create new (recommended)

To bypass this guard for a deliberate fixup (e.g. a follow-up to a shipped PR),
set the bypass in the LAUNCHING shell:

    MERGED_PR_COMMIT_OK=1 claude
EOF
        exit 2
        ;;
    1)
        # Not merged — allow.
        exit 0
        ;;
    *)
        # Uncertain / forge unreachable — fail open with a warning.
        echo "block-merged-pr-commit: warn — forge unreachable — merged-PR commit guard skipped" >&2
        exit 0
        ;;
esac
