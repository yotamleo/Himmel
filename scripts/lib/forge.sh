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
#   2. else `git remote get-url origin`, its HOST (https, ssh://, scp-like; the
#      domain or a subdomain of it, case-insensitive) matched against
#      github.com / bitbucket.org — never a substring of the URL (HIMMEL-3325).
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

# _forge_origin_host <url> — echo the lowercased HOST of a git remote URL:
#   scheme://[userinfo@]host[:port]/path   (https, http, ssh, git, file, …)
#   [userinfo@]host:path                   (scp-like; no `://` before the first `/`)
# Anything else (a local path) has no host and echoes empty. Case globs and
# parameter expansion only — bash 3.2-safe.
_forge_origin_host() {
    local u rest authority scheme
    u=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    scheme="${u%%://*}"
    case "$u" in
        *://*)
            # A real scheme is [a-z0-9+.-]+ — `git@host:p/x://y` is scp-like, not a URL.
            case "$scheme" in
                ''|*[!a-z0-9+.-]*) authority="${u%%[:/]*}" ;;
                *) rest="${u#*://}"; authority="${rest%%/*}" ;;
            esac
            ;;
        *) authority="${u%%[:/]*}" ;;
    esac
    authority="${authority##*@}"   # drop userinfo
    printf '%s' "${authority%%:*}" # drop :port
}

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

    # HIMMEL-3325: decide on the HOST, never a substring of the URL — a path
    # segment (github.com/bitbucket.org/x) or a longer hostname (notbitbucket.org)
    # must not win. The host is the domain itself or a subdomain of it (git's SSH
    # over 443 is ssh.github.com). Case-insensitive.
    # scripts/himmelctl/lib/status-report.js targetUsesBitbucket applies the same
    # rule; scripts/lib/fixtures/forge-origins.tsv holds the shared answers.
    local host
    host=$(_forge_origin_host "$origin")
    case "$host" in
        github.com|*.github.com)       printf 'github\n';    return 0 ;;
        bitbucket.org|*.bitbucket.org) printf 'bitbucket\n'; return 0 ;;
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
