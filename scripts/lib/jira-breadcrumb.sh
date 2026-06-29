#!/usr/bin/env bash
# jira-breadcrumb.sh — shared resolver for the jira-mutation breadcrumb path
# (HIMMEL-618). bash 3.2-safe; source this file, then call the functions.
#
# The jira CLI WRITER (scripts/jira/src/breadcrumb.ts) and the SessionEnd hook
# READER (scripts/hooks/jira-nudge-on-end.sh) MUST agree byte-for-byte on the
# breadcrumb file path. This file is the reader half; keep its sanitization and
# key derivation in lockstep with breadcrumb.ts.
#
# Layout: $HOME/.claude/jira-breadcrumbs/<repo-key>__<branch>.log
#   repo-key = basename of `git remote get-url origin`, trailing '.git' stripped
#              (stable across worktrees — they share one origin).
#   branch   = `git branch --show-current` (or "detached").
# Both tokens are sanitized: any char outside [A-Za-z0-9._-] becomes '-'.
# Each line: <epoch>\t<TICKET>.

# breadcrumb_sanitize <str> → echo sanitized token (mirrors breadcrumb.ts).
breadcrumb_sanitize() {
    printf '%s' "${1:-}" | sed 's/[^A-Za-z0-9._-]/-/g'
}

# breadcrumb_repo_key <cwd> → echo the repo key.
breadcrumb_repo_key() {
    local cwd="$1" remote base top
    remote="$(git -C "$cwd" remote get-url origin 2>/dev/null)"
    if [ -n "$remote" ]; then
        base="${remote%/}"          # strip a trailing slash
        base="${base##*/}"          # basename (split on '/')
        base="${base%.git}"         # strip trailing .git
    else
        top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
        base="${top##*/}"
        [ -z "$base" ] && base="unknown-repo"
    fi
    printf '%s' "$base"
}

# breadcrumb_branch <cwd> → echo the current branch (or "detached").
breadcrumb_branch() {
    local cwd="$1" b
    b="$(git -C "$cwd" branch --show-current 2>/dev/null)"
    [ -z "$b" ] && b="detached"
    printf '%s' "$b"
}

# breadcrumb_dir → echo the machine-global breadcrumb directory.
breadcrumb_dir() {
    printf '%s' "${HOME}/.claude/jira-breadcrumbs"
}

# breadcrumb_file <cwd> → echo the full breadcrumb log path for that repo+branch.
breadcrumb_file() {
    local cwd="$1" key branch
    key="$(breadcrumb_sanitize "$(breadcrumb_repo_key "$cwd")")"
    branch="$(breadcrumb_sanitize "$(breadcrumb_branch "$cwd")")"
    printf '%s/%s__%s.log' "$(breadcrumb_dir)" "$key" "$branch"
}

# breadcrumb_mutated_since <cwd> <start_epoch> → rc 0 if the breadcrumb log has
# any line with epoch >= start_epoch (i.e. a jira mutation happened this
# session window); rc 1 otherwise. No output.
breadcrumb_mutated_since() {
    local cwd="$1" start="$2" file ep _rest
    file="$(breadcrumb_file "$cwd")"
    [ -f "$file" ] || return 1
    while IFS="$(printf '\t')" read -r ep _rest; do
        case "$ep" in ''|*[!0-9]*) continue ;; esac
        if [ "$ep" -ge "$start" ] 2>/dev/null; then
            return 0
        fi
    done < "$file"
    return 1
}
