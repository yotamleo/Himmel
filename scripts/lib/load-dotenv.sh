#!/usr/bin/env bash
# load-dotenv.sh — shell-side .env key loader (HIMMEL-335).
#
# Reads the primary checkout's .env and exports requested keys into the
# environment ONLY if they are currently ABSENT, where absent means UNSET **or
# EMPTY** (a live non-empty value wins). This makes <repo-root>/.env a real
# config source for the handover shell tooling (HANDOVER_DIR, USER_SLUG) — not
# just for the Jira CLI.
#
# HIMMEL-1922: the empty half is load-bearing, not incidental. Every caller
# guards with `[ -z "${KEY-}" ]` — empty is not a usable value — so a loader
# that counted set-empty as "already provided" loaded nothing and still
# returned 0. The Jira CLI's loadEnv() (scripts/jira/src/client.ts) uses JS
# `??=`, under which an exported empty string DOES win; that half of the mirror
# no longer holds and is tracked separately.
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
    local _ld_root=""
    if [ "${1:-}" = "--root" ]; then
        _ld_root="$2"; shift 2
    fi
    local _ld_keys=("$@")
    [ "${#_ld_keys[@]}" -eq 0 ] && _ld_keys=(HANDOVER_DIR USER_SLUG)

    local _ld_envfile
    # An explicit --root bypasses CWD git resolution (never trust the CWD repo).
    [ -n "$_ld_root" ] || { _ld_root=$(_load_dotenv_root) || return 0; }
    _ld_envfile="$_ld_root/.env"
    [ -f "$_ld_envfile" ] || return 0

    local _ld_key _ld_line _ld_val
    local _ld_pending=()
    for _ld_key in "${_ld_keys[@]}"; do
        # Absent means UNSET **or EMPTY** (HIMMEL-1922). `declare -p` is Bash
        # 3.2-compatible and short-circuits the indirect expansion when the key
        # is genuinely unset, so this stays `set -u`-safe. Every caller guards
        # with `[ -z "${KEY-}" ]`, i.e. empty is not a usable value; a loader
        # that treated set-empty as "already provided" silently loaded nothing
        # and still returned 0 — the exact silent-failure class this family of
        # tickets exists to remove. Non-clobbering therefore protects a live
        # NON-EMPTY value.
        if ! declare -p "$_ld_key" >/dev/null 2>&1 || [ -z "${!_ld_key:-}" ]; then
            _ld_pending[${#_ld_pending[@]}]="$_ld_key"
        fi
    done
    [ "${#_ld_pending[@]}" -gt 0 ] || return 0

    # Read .env once. awk compares the complete trimmed key (the equivalent of
    # anchored ^KEY= matching), emits only the first match for each requested
    # key, and leaves value trimming to the existing shell helper. The helper
    # therefore forks at most once per requested match, not once per .env line.
    while IFS= read -r _ld_line || [ -n "$_ld_line" ]; do
        _ld_key="${_ld_line%%=*}"
        _ld_val=$(_load_dotenv_trim "${_ld_line#*=}")
        export "$_ld_key=$_ld_val"
    done < <(
        awk '
            BEGIN {
                for (i = 2; i < ARGC; i++) {
                    wanted[ARGV[i]] = 1
                    delete ARGV[i]
                }
            }
            {
                line = $0
                sub(/\r$/, "", line)
                if (line == "" || line ~ /^#/) next

                equals = index(line, "=")
                if (equals == 0) next

                key = substr(line, 1, equals - 1)
                sub(/^[[:space:]]+/, "", key)
                sub(/[[:space:]]+$/, "", key)
                if (!(key in wanted) || (key in seen)) next

                seen[key] = 1
                print key "=" strip_comment(substr(line, equals + 1))
            }
            # HIMMEL-2462: drop an unquoted trailing comment. The marker is
            # WHITESPACE followed by "#", per the dotenv convention — so
            # `URL=http://x/#frag` keeps its fragment and only a real gutter
            # comment goes. A value is quoted only when it BEGINS with a quote
            # (skip leading whitespace, then check the first non-whitespace
            # char) — a quote appearing later inside an unquoted value is DATA,
            # not structure. Inside a DOUBLE-quoted value a backslash escapes
            # the next character, so `\"` does not close the quote; inside a
            # SINGLE-quoted value a backslash is a LITERAL character (shell/
            # dotenv convention — a single-quoted trailing-backslash Windows
            # path must still close on the real closing quote), so escaping
            # applies only when the opening quote was `"`. A "#" inside quotes is
            # data; an UNTERMINATED quote keeps the whole remainder rather
            # than guessing where a broken value ends. Trailing whitespace is
            # left to _load_dotenv_trim. Surrounding quotes are still NOT
            # stripped (HIMMEL-1493 covers that).
            #
            # Why this matters: .env.example USED TO ship
            # `JIRA_PROJECT_KEY=HIMMEL   # default project for jira ops`, and
            # check-commit-msg.sh builds its ticket pattern from that key. Every
            # machine installed from that .env.example was running the
            # commit-msg gate with the impossible pattern
            # `HIMMEL   # default project for jira ops-[0-9]+`.
            function strip_comment(v,    i, c, q, n, started, esc) {
                n = length(v)
                q = ""
                started = 0
                esc = 0
                for (i = 1; i <= n; i++) {
                    c = substr(v, i, 1)
                    if (!started) {
                        if (c == " " || c == "\t") continue
                        started = 1
                        if (c == "\"" || c == "'"'"'") { q = c; continue }
                    }
                    if (q != "") {
                        if (q == "\"" && esc) { esc = 0; continue }
                        if (q == "\"" && c == "\\") { esc = 1; continue }
                        if (c == q) q = ""
                        continue
                    }
                    if (c == "#" && i > 1 && substr(v, i - 1, 1) ~ /[ \t]/) {
                        return substr(v, 1, i - 1)
                    }
                }
                return v
            }
        ' "$_ld_envfile" "${_ld_pending[@]}"
    )
}
