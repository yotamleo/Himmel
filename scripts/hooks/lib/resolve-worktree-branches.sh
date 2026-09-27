#!/usr/bin/env bash
# HIMMEL-3676 (J1322C, Critical): resolve each named .claude/worktrees/ path
# in $2 (one per line) to its branch, using ONLY one `git worktree list
# --porcelain` read against the TRUSTED cwd ($1) plus pure string matching.
# Never `git -C`s a named path, and never opens/stats anything inside a named
# path's .git -- only `cd -P`/`pwd -P`, which resolve via directory-traversal
# syscalls and cannot block on a FIFO the way `git rev-parse` blocked on a
# FIFO .git/HEAD (verdict J1322C finding 1). Prints one line per input path:
# "BRANCH <name>" or "UNRESOLVED <path>".
#
# Meant to be run under a deadline (see _run_bounded in
# guard-implementor-dispatch.sh) -- it does no bounding of its own.
set -u

round_cwd=$1
round_paths_file=$2

round_wt_list=$(git -C "$round_cwd" worktree list --porcelain 2>/dev/null) || round_wt_list=""

while IFS= read -r round_named_path; do
    [ -n "$round_named_path" ] || continue
    case "$round_named_path" in
        /*) ;;
        *)
            printf 'UNRESOLVED %s\n' "$round_named_path"
            continue
            ;;
    esac
    round_named_canon=$( (cd -P -- "$round_named_path" 2>/dev/null && pwd -P) 2>/dev/null ) || round_named_canon=""
    if [ -z "$round_named_canon" ]; then
        printf 'UNRESOLVED %s\n' "$round_named_path"
        continue
    fi
    round_wt_entry_path=""
    round_wt_branch=""
    while IFS= read -r round_wt_line; do
        case "$round_wt_line" in
            "worktree "*)
                round_wt_entry_path=${round_wt_line#worktree }
                ;;
            "branch "*)
                if [ -n "$round_wt_entry_path" ]; then
                    round_wt_entry_canon=$( (cd -P -- "$round_wt_entry_path" 2>/dev/null && pwd -P) 2>/dev/null ) || round_wt_entry_canon=""
                    if [ -n "$round_wt_entry_canon" ] && [ "$round_wt_entry_canon" = "$round_named_canon" ]; then
                        round_branch_ref=${round_wt_line#branch }
                        round_wt_branch=${round_branch_ref#refs/heads/}
                    fi
                fi
                ;;
            "")
                round_wt_entry_path=""
                ;;
        esac
    done <<EOF
$round_wt_list
EOF
    if [ -z "$round_wt_branch" ]; then
        printf 'UNRESOLVED %s\n' "$round_named_path"
    else
        printf 'BRANCH %s\n' "$round_wt_branch"
    fi
done < "$round_paths_file"
