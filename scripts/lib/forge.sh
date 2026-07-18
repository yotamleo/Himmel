#!/usr/bin/env bash
# forge.sh — the forge-dispatch seam (HIMMEL-326).
#
# A single forge abstraction with two backends, selected per-repo from the
# `origin` remote URL. Source this file, then call the forge_* verbs; each
# routes to the github or bitbucket backend. The verbs cover exactly the
# operations himmel uses today — no speculative interface.
#
# Detection precedence (spec §2, exhaustive — no ambiguity unattended):
#   1. $FORGE (github|bitbucket) verbatim — the only disambiguator for mixed
#      remotes and the test override.
#   2. else `git remote get-url origin`, matched against the host regexes
#      (https + ssh, optional trailing .git, case-insensitive host).
#   3. else (no origin, or matches neither) → non-zero + actionable message.
#      Never infer the forge from a non-origin remote (silent wrong-API risk).
#
# Backend command overrides (test seams, exact parallel to each other):
#   GH_CMD          Default `gh`.
#   BITBUCKET_CMD   Default `node <primary-checkout>/scripts/bitbucket/dist/index.js`.

# Resolve dir of this file so we can source the backends regardless of cwd.
_FORGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/forge-github.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$_FORGE_LIB_DIR/forge-github.sh"
# shellcheck source=scripts/lib/forge-bitbucket.sh
# shellcheck disable=SC1091
. "$_FORGE_LIB_DIR/forge-bitbucket.sh"

forge_detect() {
    if [ -n "${FORGE:-}" ]; then
        case "$FORGE" in
            github|bitbucket) printf '%s\n' "$FORGE"; return 0 ;;
            *)
                echo "forge_detect: invalid FORGE='$FORGE' (expected github|bitbucket)" >&2
                return 2
                ;;
        esac
    fi

    local origin
    origin=$(git remote get-url origin 2>/dev/null) || origin=""
    if [ -z "$origin" ]; then
        echo "forge_detect: cannot determine forge — set FORGE=github|bitbucket or add a github.com/bitbucket.org origin" >&2
        return 3
    fi

    # Lowercase the host portion for case-insensitive matching.
    local lc
    lc=$(printf '%s' "$origin" | tr '[:upper:]' '[:lower:]')
    case "$lc" in
        *github.com/*|*github.com:*)       printf 'github\n';    return 0 ;;
        *bitbucket.org/*|*bitbucket.org:*) printf 'bitbucket\n'; return 0 ;;
        *)
            echo "forge_detect: origin ($origin) is neither github.com nor bitbucket.org — set FORGE=github|bitbucket" >&2
            return 3
            ;;
    esac
}

# _forge_dispatch <verb> <args...> — call gh_<verb> or bb_<verb> for the
# detected forge. Internal; the public verbs below wrap it.
_forge_dispatch() {
    local verb="$1"; shift
    local f
    f=$(forge_detect) || return $?
    case "$f" in
        github)    "gh_${verb}" "$@" ;;
        bitbucket) "bb_${verb}" "$@" ;;
    esac
}

# ── public verbs ─────────────────────────────────────────────────────────────
forge_auth_status()    { _forge_dispatch forge_auth_status "$@"; }
forge_repo_nwo()       { _forge_dispatch forge_repo_nwo "$@"; }
forge_default_branch() { _forge_dispatch forge_default_branch "$@"; }
forge_user_slug()      { _forge_dispatch forge_user_slug "$@"; }
forge_pr_find_open()   { _forge_dispatch forge_pr_find_open "$@"; }
forge_pr_create()      { _forge_dispatch forge_pr_create "$@"; }
forge_pr_set_body()    { _forge_dispatch forge_pr_set_body "$@"; }
forge_pr_mergeable()   { _forge_dispatch forge_pr_mergeable "$@"; }
# args: NUMBER [VETTED_HEAD_SHA]. The optional vetted SHA binds the merge to the
# commit the gates certified (HIMMEL-1058 TOCTOU) — honored by github
# (--match-head-commit), accepted-and-ignored by bitbucket (no equivalent).
forge_pr_merge()       { _forge_dispatch forge_pr_merge "$@"; }
forge_pr_has_merged()  { _forge_dispatch forge_pr_has_merged "$@"; }
# issue create (CR deferred-issue filing, HIMMEL-327). args: REPO TITLE BODY LABEL.
# Echoes the issue URL on success. The bitbucket backend returns rc 3 when the
# issue tracker is disabled (spec §5.2) so the caller can degrade gracefully.
forge_issue_create()   { _forge_dispatch forge_issue_create "$@"; }
