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

# _load_dotenv_primary_for <dir> (HIMMEL-1482) — resolve the .env-bearing root for
# a CANDIDATE directory, for launchers that pin the .env to their OWN repo root via
# `load_dotenv --root` (which deliberately bypasses _load_dotenv_root's CWD-based
# resolution). The gitignored .env lives ONLY in the primary checkout and is never
# copied into linked worktrees, so a launcher invoked from a worktree copy of itself
# (its parent dir is a worktree root) finds no .env at <dir> and would exit 2.
#   <dir>/.env present             → echo <dir> (already the .env-bearing root)
#   <dir> is a linked git worktree → echo the PRIMARY checkout root (parent of
#                                    `git rev-parse --git-common-dir`) when its
#                                    .env exists; emit ONE advisory line to stderr
#   otherwise                      → echo <dir> (caller's missing-.env path applies
#                                    — load_dotenv then no-ops, rc 0)
# Mirrors glm-env.ts mainCheckoutRoot() (HIMMEL-654) for the bash side. Returns the
# path on stdout; the advisory is the helper's ONLY stderr output.
_load_dotenv_primary_for() {  # $1 = candidate root dir
    local dir="${1:-}" common primary dir_abs toplevel gitdir dir_phys
    [ -n "$dir" ] || dir="$(_load_dotenv_root)"
    [ -f "$dir/.env" ] && { printf '%s' "$dir"; return 0; }
    dir_abs=$(cd "$dir" 2>/dev/null && pwd) || { printf '%s' "$dir"; return 0; }
    # Resolve the primary only when <dir> is a linked worktree. cd into <dir>
    # first so a relative --git-common-dir resolves against <dir> (not the shell
    # cwd); an absolute path cd's equally well — `( cd "$common/.." && pwd )` is
    # the same idiom _load_dotenv_root uses.
    if common=$(cd "$dir" && git rev-parse --git-common-dir 2>/dev/null) && [ -n "$common" ]; then
        primary=$(cd "$dir" && cd "$common/.." 2>/dev/null && pwd) || primary=""
        # HIMMEL-1482 R2: restrict the fallback to GENUINE linked-worktree ROOTS.
        # r1 gated only on `primary != candidate`, so ANY directory inside ANY
        # checkout qualified — a hermetically pinned root like <worktree>/scripts
        # (or <primary>/scripts) resolved common-dir to the real .git, differed
        # from the candidate, and silently loaded the operator's .env, breaking
        # the documented hermetic override. Two guards:
        #  (1) the candidate must BE its checkout root: --show-toplevel (git's
        #      resolved, physical form) == the candidate's physical path (pwd -P),
        #      so a NESTED dir inside a worktree or the primary never qualifies;
        #  (2) the checkout must be genuinely LINKED: --git-dir differs from
        #      --git-common-dir (equal = primary checkout → nothing to fall back
        #      FROM). Both resolve relative to <dir>, so the raw outputs compare.
        dir_phys=$(cd "$dir" && pwd -P)
        toplevel=$(cd "$dir" && git rev-parse --show-toplevel 2>/dev/null) || toplevel=""
        # Re-resolve git's toplevel through bash cd+pwd -P so it lands in the
        # same physical (MSYS on Windows) form as dir_phys — git for Windows
        # prints a drive-letter path that never string-equals a bash pwd, and on
        # macOS /tmp → /private/tmp must resolve identically on both sides.
        [ -n "$toplevel" ] && toplevel=$(cd "$toplevel" 2>/dev/null && pwd -P)
        gitdir=$(cd "$dir" && git rev-parse --git-dir 2>/dev/null) || gitdir=""
        if [ -n "$primary" ] && [ -n "$toplevel" ] && [ "$toplevel" = "$dir_phys" ] \
           && [ -n "$gitdir" ] && [ "$gitdir" != "$common" ] \
           && [ "$primary" != "$dir_abs" ] && [ -f "$primary/.env" ]; then
            echo "load-dotenv: .env absent under worktree '$dir_abs' — reading the primary checkout's .env at '$primary'." >&2
            printf '%s' "$primary"
            return 0
        fi
    fi
    printf '%s' "$dir"
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
