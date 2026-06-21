#!/usr/bin/env bash
# load-dotenv.sh — shell-side .env key loader (HIMMEL-335).
#
# Mirrors the Jira CLI's loadEnv() (scripts/jira/src/client.ts): reads the
# primary checkout's .env and exports requested keys into the environment
# ONLY if they are currently unset (a value already in the live env wins,
# same as JS `??=`). This makes <repo-root>/.env a real config source for the
# handover shell tooling (HANDOVER_DIR, USER_SLUG) — not just for the Jira CLI.
#
# Usage — source this file, then:
#   load_dotenv [KEY ...]
#   load_dotenv --root <dir> [KEY ...]
# With no keys, loads the default keys: HANDOVER_DIR USER_SLUG.
#
# The .env path is resolved like the Jira CLI: the parent of
# `git rev-parse --git-common-dir`, so from inside a git worktree it still
# finds the PRIMARY checkout's .env (the gitignored .env is not copied into
# worktrees). Falls back to two levels up from this script if git is absent.
#
# `--root <dir>` (HIMMEL-460): load <dir>/.env and BYPASS the CWD-based
# `_load_dotenv_root` resolution entirely (no `git rev-parse` against the
# process CWD). The caller has already resolved the correct root — used by the
# SessionStart inject-initiative hook so a session launched inside an UNRELATED
# git repo never reads THAT repo's .env.
#
# Safety: never `source`s the file (no arbitrary code execution). Extracts
# only the requested `KEY=` lines; skips comments, blanks, and lines without
# '='; strips surrounding whitespace and a trailing CR (CRLF-safe).

# Strip leading/trailing whitespace + trailing CR. Pure (stdout only).
_load_dotenv_trim() {
    local s="$1"
    s="${s%$'\r'}"
    s="${s#"${s%%[![:space:]]*}"}"   # ltrim
    s="${s%"${s##*[![:space:]]}"}"   # rtrim
    printf '%s' "$s"
}

# Resolve the primary checkout root (where the gitignored .env lives).
_load_dotenv_root() {
    local common
    if common=$(git rev-parse --git-common-dir 2>/dev/null); then
        ( cd "$common/.." && pwd ) && return 0
    fi
    ( cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd )
}

load_dotenv() {
    local root=""
    if [ "${1:-}" = "--root" ]; then
        root="$2"; shift 2
    fi
    local keys=("$@")
    [ "${#keys[@]}" -eq 0 ] && keys=(HANDOVER_DIR USER_SLUG)

    local envfile
    # An explicit --root bypasses CWD git resolution (never trust the CWD repo).
    [ -n "$root" ] || { root=$(_load_dotenv_root) || return 0; }
    envfile="$root/.env"
    [ -f "$envfile" ] || return 0

    local line key val want
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in ''|'#'*) continue ;; esac
        [ "${line#*=}" = "$line" ] && continue   # no '=' → not a KEY=VALUE line
        key=$(_load_dotenv_trim "${line%%=*}")
        for want in "${keys[@]}"; do
            # First match wins: once exported, ${!want} is non-empty so the
            # next matching line for the same key is skipped here too.
            if [ "$key" = "$want" ] && [ -z "${!want:-}" ]; then
                val=$(_load_dotenv_trim "${line#*=}")
                export "$want=$val"
            fi
        done
    done < "$envfile"
}
