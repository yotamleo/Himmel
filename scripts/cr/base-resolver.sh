#!/usr/bin/env bash
# Shared origin-first CR diff-base resolution (HIMMEL-2787).
# Bash 3.2-safe. Sourcing defines functions only.
# Platform guard: requires POSIX Bash 3.2+; on Windows, run under Git Bash.

# cr_fetch_base <repo> <bare-branch>
# Refresh origin/<branch> once at the start of a review row. Repositories with
# no origin (notably hermetic fixtures) have nothing to fetch and fall through
# to the local-ref resolver below.
cr_fetch_base() {
    local _cfr_repo="$1" _cfr_branch="$2"
    case "$_cfr_branch" in
        refs/remotes/origin/*) _cfr_branch="${_cfr_branch#refs/remotes/origin/}" ;;
        origin/*) _cfr_branch="${_cfr_branch#origin/}" ;;
        refs/heads/*) _cfr_branch="${_cfr_branch#refs/heads/}" ;;
    esac
    git -C "$_cfr_repo" remote get-url origin >/dev/null 2>&1 || return 0
    git -C "$_cfr_repo" fetch --quiet origin \
        "+refs/heads/$_cfr_branch:refs/remotes/origin/$_cfr_branch"
}

# cr_resolve_base_ref <repo> <branch-or-ref>
# Prefer the remote-tracking ref whenever it exists. Fall back to the local
# branch only when origin/<branch> is absent. If neither exists, preserve the
# caller's name so git produces the useful failing-ref diagnostic. Always
# returns a FULLY QUALIFIED ref (refs/remotes/origin/<b> or refs/heads/<b>),
# never the short origin/<b> or bare <b> form: an unqualified name is resolved
# through git's ambiguous-ref precedence, where refs/tags/<name> and
# refs/heads/<name> are checked BEFORE refs/remotes/<name> — a tag or branch
# literally named origin/main would shadow the verified tracking ref and send
# callers to the wrong commit (codex-2 CR round 2, HIMMEL-2780/2787).
cr_resolve_base_ref() {
    local _crr_repo="$1" _crr_input="$2" _crr_branch
    case "$_crr_input" in
        refs/remotes/origin/*)
            _crr_branch="${_crr_input#refs/remotes/origin/}"
            ;;
        origin/*)
            _crr_branch="${_crr_input#origin/}"
            ;;
        refs/heads/*)
            _crr_branch="${_crr_input#refs/heads/}"
            ;;
        *)
            _crr_branch="$_crr_input"
            ;;
    esac

    if git -C "$_crr_repo" rev-parse --verify --quiet \
        "refs/remotes/origin/$_crr_branch^{commit}" >/dev/null 2>&1; then
        printf 'refs/remotes/origin/%s' "$_crr_branch"
    elif git -C "$_crr_repo" rev-parse --verify --quiet \
        "refs/heads/$_crr_branch^{commit}" >/dev/null 2>&1; then
        printf 'refs/heads/%s' "$_crr_branch"
    else
        printf '%s' "$_crr_input"
    fi
}
