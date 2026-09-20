#!/usr/bin/env bash
# release-check.sh — release-tag lookup + version compare for a himmel install
# that is NOT a git checkout (HIMMEL-3247; prerequisite P1 of HIMMEL-3059).
#
# WHY this exists: himmel updates by `git pull` of its own checkout
# (scripts/himmel-update.sh). A tarball or native-package install has no .git, so
# there is no upstream to be behind — that install would neither update nor even
# learn a newer release exists. This is the git-free half: ask GitHub for the
# latest RELEASE tag and compare it with the install's VERSION file.
#
# Two ways to use it:
#   . scripts/lib/release-check.sh          # sourced: defines release_* functions
#   bash scripts/lib/release-check.sh --refresh <cache-file>
#       # executed: one lookup, cache written ATOMICALLY and only on a definite
#       # answer. This is what the SessionStart hook runs DETACHED, so the
#       # network never sits on the session-start path (HIMMEL-1844).
#
# Integrity position (HIMMEL-3059 ADR): the ONLY thing fetched is one tag name.
# The URL below is a constant, deliberately NOT overridable from the environment
# — a hostile .env or settings file must not be able to steer the check at a
# non-release endpoint. https is pinned (including across redirects), and the
# reply is accepted only if its tag_name matches the strict release-tag grammar,
# so nothing else from the response (release notes, a tampered body) can reach a
# model's context or a shell. Nothing is downloaded or executed here.
#
# Failure vocabulary (cache-side `.fail` file, and release_fetch_latest's rc):
#   rc 0  a release tag was found (RELEASE_LATEST_TAG)
#   rc 3  HTTP 404 — no release has been published yet (a definite answer)
#   rc 1  could not ask: no curl, network error, rate limit, any other HTTP code
#   rc 2  the API answered 200 but with no valid release tag
#
# Bash 3.2 compatible.

# Fixed, never read from the environment (see the integrity note above).
HIMMEL_RELEASES_API="https://api.github.com/repos/yotamleo/Himmel/releases/latest"
# shellcheck disable=SC2034  # read by the callers that source this file
HIMMEL_RELEASES_PAGE="https://github.com/yotamleo/Himmel/releases"

# release_tag_parts <tag-or-version> — echoes "<maj> <min> <pat> <pre>" (pre is
# NONE for a stable release); rc 1 if it is not vX.Y.Z / X.Y.Z[-pre.N]. The same
# grammar as himmel-update.sh's release-channel seam (_channel_tag_parts).
release_tag_parts() {
    local v="${1#v}"
    if [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-pre\.([0-9]+))?$ ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]} ${BASH_REMATCH[5]:-NONE}"
        return 0
    fi
    return 1
}

# release_is_older <a> <b> — rc 0 iff version a is strictly older than b. A
# stable release outranks any -pre.N of the same X.Y.Z; -pre.N compare numerically.
release_is_older() {
    local pa pb a_maj a_min a_pat a_pre b_maj b_min b_pat b_pre
    pa=$(release_tag_parts "$1") || return 1
    pb=$(release_tag_parts "$2") || return 1
    read -r a_maj a_min a_pat a_pre <<<"$pa"
    read -r b_maj b_min b_pat b_pre <<<"$pb"
    [ "$a_maj" -ne "$b_maj" ] && { [ "$a_maj" -lt "$b_maj" ]; return; }
    [ "$a_min" -ne "$b_min" ] && { [ "$a_min" -lt "$b_min" ]; return; }
    [ "$a_pat" -ne "$b_pat" ] && { [ "$a_pat" -lt "$b_pat" ]; return; }
    [ "$a_pre" = "$b_pre" ] && return 1
    [ "$b_pre" = "NONE" ] && return 0
    [ "$a_pre" = "NONE" ] && return 1
    [ "$a_pre" -lt "$b_pre" ]
}

# release_installed_version <root> — echoes the install's VERSION (first line,
# whitespace and a leading v stripped); rc 1 if absent, unreadable, or malformed.
release_installed_version() {
    local raw v
    [ -r "$1/VERSION" ] || return 1
    IFS= read -r raw < "$1/VERSION" || [ -n "$raw" ] || return 1
    v=$(printf '%s' "$raw" | tr -d '[:space:]')
    v="${v#v}"
    release_tag_parts "$v" >/dev/null || return 1
    printf '%s\n' "$v"
}

# release_fetch_latest — one bounded lookup. Sets RELEASE_LATEST_TAG on rc 0 and
# RELEASE_FAIL_REASON otherwise (a fixed vocabulary — no-curl | network |
# bad-response | http-<3 digits> — safe to print back). Call it directly, not in
# $(...): the globals are the result. Synchronous, so a session-start caller
# must run it detached.
release_fetch_latest() {
    local out code body tag
    RELEASE_LATEST_TAG=""; RELEASE_FAIL_REASON=""
    if ! command -v curl >/dev/null 2>&1; then RELEASE_FAIL_REASON="no-curl"; return 1; fi
    if ! out=$(curl -sS --proto '=https' --proto-redir '=https' -L --max-redirs 3 --max-time 10 \
        -H 'Accept: application/vnd.github+json' \
        -w '\n%{http_code}' "$HIMMEL_RELEASES_API" 2>/dev/null); then
        RELEASE_FAIL_REASON="network"; return 1
    fi
    code="${out##*$'\n'}"
    body="${out%$'\n'*}"
    case "$code" in
        200) ;;
        404) return 3 ;;
        [0-9][0-9][0-9]) RELEASE_FAIL_REASON="http-$code"; return 1 ;;
        *) RELEASE_FAIL_REASON="bad-response"; return 1 ;;
    esac
    tag=$(printf '%s\n' "$body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    if ! release_tag_parts "$tag" >/dev/null; then RELEASE_FAIL_REASON="bad-response"; return 2; fi
    RELEASE_LATEST_TAG="$tag"
    return 0
}

# --refresh <cache-file>: one lookup, then update the cache.
#   definite answer (tag, or "none" for a 404) → cache written atomically, .fail removed
#   no definite answer                         → cache LEFT ALONE (an old answer beats
#                                                 a blank one), reason written to .fail
release_refresh() {
    local cache="$1" rc=0 answer tmp
    [ -n "$cache" ] || return 2
    mkdir -p "$(dirname "$cache")" 2>/dev/null || return 1
    release_fetch_latest || rc=$?
    case "$rc" in
        0) answer="$RELEASE_LATEST_TAG" ;;
        3) answer="none" ;;
        *)
            printf '%s\n' "${RELEASE_FAIL_REASON:-network}" > "$cache.fail" 2>/dev/null || true
            return 1 ;;
    esac
    tmp="$cache.tmp.$$"
    if printf '%s\n' "$answer" > "$tmp" 2>/dev/null && mv -f "$tmp" "$cache" 2>/dev/null; then
        rm -f "$cache.fail" 2>/dev/null || true
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --refresh) release_refresh "${2:-}"; exit $? ;;
        *) echo "usage: release-check.sh --refresh <cache-file>" >&2; exit 2 ;;
    esac
fi
