#!/usr/bin/env bash
# load-dotenv.sh — shell-side .env key loader.
#
# Reads the primary checkout's .env and exports requested keys into the
# environment ONLY if they are currently ABSENT, where absent means UNSET **or
# EMPTY** (a live non-empty value wins). This makes <repo-root>/.env a real
# config source for the handover shell tooling (HANDOVER_DIR, USER_SLUG) — not
# just for the Jira CLI.
#
# The empty half is load-bearing, not incidental. Every caller
# guards with `[ -z "${KEY-}" ]` — empty is not a usable value — so a loader
# that counted set-empty as "already provided" loaded nothing and still
# returned 0. The Jira CLI's loadEnv() (scripts/jira/src/client.ts) uses JS
# `??=`, under which an exported empty string DOES win; that half of the mirror
# no longer holds and is tracked separately.
#
# Usage — source this file, then:
#   load_dotenv [KEY ...]
#   load_dotenv --root <dir> [KEY ...]
# With no keys, does nothing: every consumer must name its allowlist.
# ponytail: HIMMEL-4915 audits launch sites and passes --no-env-file;
# Bun auto-loads cwd .env before any explicit reader.
#
# The .env path is resolved like the Jira CLI: the parent of
# `git rev-parse --git-common-dir`, so from inside a git worktree it still
# finds the PRIMARY checkout's .env (the gitignored .env is not copied into
# worktrees). Falls back to two levels up from this script if git is absent.
#
# `--root <dir>`: load <dir>/.env and BYPASS the CWD-based
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

# _load_dotenv_primary_for <dir> — resolve the .env-bearing root for
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
# Mirrors glm-env.ts mainCheckoutRoot() for the bash side. Returns the
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
        # Restrict the fallback to GENUINE linked-worktree ROOTS.
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

# _load_dotenv_envfile [<root>] — the .env path load_dotenv reads: <root>/.env
# when a root is given (an explicit --root bypasses CWD git resolution — never
# trust the CWD repo), else the himmelctl cache dir's .env when present, else
# the git-resolved primary checkout's .env. Prints nothing when unresolvable.
_load_dotenv_envfile() {
    local _lf_root="${1:-}"
    if [ -n "$_lf_root" ]; then
        printf '%s/.env' "$_lf_root"
        return 0
    fi
    # A read-only install tree (e.g. a packaged /usr/share
    # prefix) can never HAVE an in-tree .env, so an adopter's overrides land
    # under the himmelctl cache dir instead. Readers check there FIRST, then
    # fall back to the git-resolved root, so an existing writable clone's
    # .env is unaffected.
    local _lf_cache="${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}"
    if [ -f "$_lf_cache/.env" ]; then
        printf '%s/.env' "$_lf_cache"
        return 0
    fi
    _lf_root=$(_load_dotenv_root) || return 0
    printf '%s/.env' "$_lf_root"
}

load_dotenv() {
    local _ld_root=""
    if [ "${1:-}" = "--root" ]; then
        _ld_root="$2"; shift 2
    fi
    local _ld_keys=("$@")
    [ "${#_ld_keys[@]}" -gt 0 ] || return 0

    local _ld_key _ld_line _ld_val _ld_rc=0
    local _ld_pending=()
    for _ld_key in "${_ld_keys[@]}"; do
        # Absent means UNSET **or EMPTY**. `declare -p` is Bash
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

    # Config layers first (defined at the end of this file):
    # a behaviour key comes from ~/.himmel/himmel.conf(.local), a gate-policy
    # key from ~/.himmel/config.json .policy. A secret key never comes from
    # either; it falls through to .env below. This advisory reader keeps going
    # on an unreadable config.json (the notice says so); only load_policy, the
    # gate reader, fails closed on it.
    if declare -F _himmel_config_layers >/dev/null 2>&1; then
        local _ld_found _ld_rest=()
        if ! _ld_found=$(_himmel_config_layers "${_ld_pending[@]}"); then
            printf 'himmel: ~/.himmel/config.json is unreadable; policy keys fall back to .env\n' >&2
        fi
        while IFS= read -r _ld_line; do
            [ -n "$_ld_line" ] || continue
            # shellcheck disable=SC2163 # exports the KEY=value the line holds
            export "$_ld_line"
        done <<EOF
$_ld_found
EOF
        for _ld_key in "${_ld_pending[@]}"; do
            if [ -z "${!_ld_key:-}" ]; then
                _ld_rest[${#_ld_rest[@]}]="$_ld_key"
            fi
        done
        [ "${#_ld_rest[@]}" -gt 0 ] || return 0
        _ld_pending=("${_ld_rest[@]}")
    fi

    local _ld_envfile
    _ld_envfile=$(_load_dotenv_envfile "$_ld_root")
    [ -n "$_ld_envfile" ] && [ -f "$_ld_envfile" ] || return 0

    # Read .env once. The helper forks at most once per requested match, not
    # once per .env line. A non-secret key found here is legacy: it still
    # applies for one release, with one deprecation notice per call.
    local _ld_legacy=()
    while IFS= read -r _ld_line || [ -n "$_ld_line" ]; do
        _ld_key="${_ld_line%%=*}"
        _ld_val=$(_load_dotenv_trim "${_ld_line#*=}")
        export "$_ld_key=$_ld_val"
        if declare -F _himmel_key_class >/dev/null 2>&1 \
            && [ "$(_himmel_key_class "$_ld_key")" != secret ]; then
            _ld_legacy[${#_ld_legacy[@]}]="$_ld_key"
        fi
    done < <(_load_dotenv_extract "$_ld_envfile" "${_ld_pending[@]}")
    if [ "${#_ld_legacy[@]}" -gt 0 ]; then
        _himmel_deprecation_notice "${_ld_legacy[@]}"
    fi
    return 0
}

# _load_dotenv_extract <file> KEY... — print `KEY=<raw value>` for the first
# line of each requested key in a dotenv-format file. Never executes the file.
# awk compares the complete trimmed key (the equivalent of anchored ^KEY=
# matching) and leaves value trimming to _load_dotenv_trim.
_load_dotenv_extract() {
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
            # Drop an unquoted trailing comment. The marker is
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
            # stripped.
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
        ' "$@"
}

# Config layers — the behaviour-config and gate-policy layers that sit beside
# .env (layer table: docs/internals/config-layers.md). They live in this file,
# not a sibling, so every copy of the loader carries load_policy.
#
#   behaviour keys  ~/.himmel/himmel.conf.local > ~/.himmel/himmel.conf
#                   (KEY=value, parsed, never sourced). load_dotenv reads them
#                   with the process env still winning.
#   policy keys     ~/.himmel/config.json .policy, the operator-owned file a
#                   guard keeps agents from writing. load_policy, the gate
#                   reader, IGNORES the process env for them.
#   secret keys     .env only. Never read from either file above.
#
# The directory is fixed at $HOME/.himmel; no env var selects another one.
# ponytail: the path follows $HOME, so a caller that controls HOME picks the
# file; clear-cr-marker's seam guard does not cover HOME (it is always set).
# Upgrade path: pin the directory from the passwd entry if a gate ever runs
# under a caller-chosen HOME.
# ponytail: policy keys live in config.json, not the tracked himmel.conf,
# because no guard covers writes to himmel.conf yet; move them once one does.

# Keys this layer serves. Anything else is a secret and stays in .env.
_himmel_key_class() {
    case "$1" in
        CR_REQUIRE_CROSS_MODEL|CR_FLOOR_FALLBACK|ARMAUTOMERGE)
            printf 'policy' ;;
        HANDOVER_DIR|USER_SLUG|LUNA_VAULT_PATH|HIMMEL_DOC_FRESHNESS|\
        HIMMEL_INITIATIVE|HIMMEL_INITIATIVE_AFK|HIMMEL_AFK|\
        HIMMEL_INITIATIVE_OVERNIGHT|HIMMEL_OVERNIGHT|\
        HIMMEL_WHERE_ARE_WE|HIMMEL_WHERE_ARE_WE_STALE_HOURS|\
        HIMMEL_WORKTREE_NUDGE|HIMMEL_UPDATE_AUTOSTASH|CR_PROFILE|\
        CR_CLAUDE_AGENTS|TICKET_ID_REQUIRED|TICKET_ID_PATTERN|\
        TICKET_ID_EXEMPT_AUTHORS|TRACKER)
            printf 'config' ;;
        *)
            printf 'secret' ;;
    esac
}

_himmel_config_dir() {
    printf '%s/.himmel' "$HOME"
}

# One stderr line naming the keys (never their values) still read from .env.
_himmel_deprecation_notice() {
    printf 'himmel: DEPRECATED: %s read from .env, which is for secrets only. Move behaviour keys to ~/.himmel/himmel.conf and policy keys to ~/.himmel/config.json .policy: run scripts/setup/migrate-env-config.sh --dry-run. Until then .env keeps working.\n' "$*" >&2
}

# _himmel_policy_json <config.json> KEY... — print KEY=value for each key
# present under .policy. Strings, numbers and booleans only; null reads as
# unset. Returns non-zero when the file cannot be parsed, node is missing, or
# .policy or a requested value has any other shape, so a gate fails closed.
_himmel_policy_json() {
    node -e '
        const fs = require("fs");
        const [file, ...keys] = process.argv.slice(1);
        const doc = JSON.parse(fs.readFileSync(file, "utf8"));
        const raw = doc && typeof doc === "object" ? doc.policy : undefined;
        if (raw !== undefined && raw !== null && (typeof raw !== "object" || Array.isArray(raw))) process.exit(3);
        const policy = raw || {};
        let out = "";
        for (const key of keys) {
            if (!Object.prototype.hasOwnProperty.call(policy, key) || policy[key] === null) continue;
            const v = policy[key];
            if (!["string", "number", "boolean"].includes(typeof v)) process.exit(3);
            const s = String(v);
            if (/[\r\n\0]/.test(s)) process.exit(3);
            out += key + "=" + s + "\n";
        }
        process.stdout.write(out);
    ' "$@" 2>/dev/null
}

# _himmel_config_layers KEY... — print KEY=value for every requested
# behaviour key found in himmel.conf(.local) and every policy key found in
# config.json. Secret keys are skipped. Non-zero only when config.json exists
# and cannot be read.
_himmel_config_layers() {
    local _hc_dir _hc_key _hc_line _hc_val _hc_file _hc_found=" "
    local _hc_cfg=() _hc_pol=()
    _hc_dir=$(_himmel_config_dir)
    for _hc_key in "$@"; do
        case "$(_himmel_key_class "$_hc_key")" in
            config) _hc_cfg[${#_hc_cfg[@]}]="$_hc_key" ;;
            policy) _hc_pol[${#_hc_pol[@]}]="$_hc_key" ;;
        esac
    done
    if [ "${#_hc_cfg[@]}" -gt 0 ]; then
        for _hc_file in "$_hc_dir/himmel.conf.local" "$_hc_dir/himmel.conf"; do
            [ -f "$_hc_file" ] || continue
            while IFS= read -r _hc_line || [ -n "$_hc_line" ]; do
                _hc_key="${_hc_line%%=*}"
                case "$_hc_found" in *" $_hc_key "*) continue ;; esac
                _hc_val=$(_load_dotenv_trim "${_hc_line#*=}")
                [ -n "$_hc_val" ] || continue
                _hc_found="$_hc_found$_hc_key "
                printf '%s=%s\n' "$_hc_key" "$_hc_val"
            done < <(_load_dotenv_extract "$_hc_file" "${_hc_cfg[@]}")
        done
    fi
    if [ "${#_hc_pol[@]}" -gt 0 ] && [ -f "$_hc_dir/config.json" ]; then
        _himmel_policy_json "$_hc_dir/config.json" "${_hc_pol[@]}" || return 1
    fi
    return 0
}

# load_policy [--root <dir>] KEY... — the gate reader for policy keys.
# Order: ~/.himmel/config.json .policy, then legacy .env (deprecation
# notice), then unset, which every gate treats as its safe default. The
# process env is never used: a value there is dropped, with a notice when it
# differs from the resolved one. Returns non-zero when a file that exists
# cannot be read, so the caller fails closed instead of using a default.
load_policy() {
    local _lp_root=""
    if [ "${1:-}" = "--root" ]; then
        _lp_root="$2"; shift 2
    fi
    [ "$#" -gt 0 ] || return 0
    local _lp_key _lp_line _lp_val _lp_out _lp_envfile _lp_i _lp_found=" "
    local _lp_keys=() _lp_env=() _lp_rest=() _lp_legacy=()
    local _lp_conf
    _lp_conf="$(_himmel_config_dir)/config.json"

    for _lp_key in "$@"; do
        if [ "$(_himmel_key_class "$_lp_key")" != policy ]; then
            printf 'load_policy: %s is not a policy key\n' "$_lp_key" >&2
            return 1
        fi
        _lp_keys[${#_lp_keys[@]}]="$_lp_key"
        _lp_env[${#_lp_env[@]}]="${!_lp_key-}"
        unset "$_lp_key"
    done

    if [ -f "$_lp_conf" ]; then
        if ! _lp_out=$(_himmel_policy_json "$_lp_conf" "${_lp_keys[@]}"); then
            printf 'himmel: ~/.himmel/config.json cannot be parsed; gate policy fails closed\n' >&2
            return 1
        fi
        while IFS= read -r _lp_line; do
            [ -n "$_lp_line" ] || continue
            _lp_found="$_lp_found${_lp_line%%=*} "
            # shellcheck disable=SC2163 # exports the KEY=value the line holds
            export "$_lp_line"
        done <<EOF
$_lp_out
EOF
    else
        printf 'himmel: no ~/.himmel/config.json; policy keys (%s) come from legacy .env or their safe defaults\n' "${_lp_keys[*]}" >&2
    fi

    for _lp_key in "${_lp_keys[@]}"; do
        case "$_lp_found" in *" $_lp_key "*) ;; *) _lp_rest[${#_lp_rest[@]}]="$_lp_key" ;; esac
    done
    if [ "${#_lp_rest[@]}" -gt 0 ]; then
        _lp_envfile=$(_load_dotenv_envfile "$_lp_root")
        if [ -n "$_lp_envfile" ] && [ -e "$_lp_envfile" ]; then
            if [ ! -r "$_lp_envfile" ]; then
                printf 'himmel: legacy .env exists but is unreadable; gate policy fails closed\n' >&2
                return 1
            fi
            while IFS= read -r _lp_line || [ -n "$_lp_line" ]; do
                _lp_key="${_lp_line%%=*}"
                _lp_val=$(_load_dotenv_trim "${_lp_line#*=}")
                export "$_lp_key=$_lp_val"
                _lp_legacy[${#_lp_legacy[@]}]="$_lp_key"
            done < <(_load_dotenv_extract "$_lp_envfile" "${_lp_rest[@]}")
            if [ "${#_lp_legacy[@]}" -gt 0 ]; then
                _himmel_deprecation_notice "${_lp_legacy[@]}"
            fi
        fi
    fi

    _lp_i=0
    for _lp_key in "${_lp_keys[@]}"; do
        if [ -n "${_lp_env[$_lp_i]}" ] && [ "${_lp_env[$_lp_i]}" != "${!_lp_key-}" ]; then
            printf 'himmel: ignoring process-env %s; gate policy is read from ~/.himmel/config.json only\n' "$_lp_key" >&2
        fi
        _lp_i=$((_lp_i + 1))
    done
    return 0
}
