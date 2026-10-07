#!/usr/bin/env bash
# choose-mode.sh -- ask for the tracker and forge, write git config (HIMMEL-4767,
# HIMMEL-4748 WP8). Reads one answer per line on stdin: tracker, then forge.
# An existing git config value is the default; Enter (or EOF) keeps it, so a
# re-run never overwrites. An answer is written only after the resolver
# (scripts/lib/project-mode.sh, the one owner) accepts it; a refusal prints the
# resolver's message and keeps the old value. Keys: himmel.tracker,
# himmel.forge (docs/configuration.md#tracker-and-forge).
#
# Source-safe: defines choose_mode on `source`; on direct invocation runs it
# only when stdin is a terminal (setup.sh stays unattended-safe). Bash 3.2-safe.
#   bash choose-mode.sh <repo-root>

_CM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/project-mode.sh"

# _cm_resolve <root> <fn> [VAR=value] -- the resolver's answer (or its refusal
# on stderr, rc 2) in <root>, with an optional candidate set by env.
_cm_resolve() {
    local root="$1" fn="$2"
    shift 2
    # shellcheck source=/dev/null
    # shellcheck disable=SC2086,SC2163  # $fn is a function name plus its flag; "$@" holds VAR=value words
    (cd "$root" && { [ $# -eq 0 ] || export "$@"; } && . "$_CM_LIB" && $fn)
}

# _cm_ask <root> <key> <var> <fn> <choices> -- one prompt, one write at most.
_cm_ask() {
    local root="$1" key="$2" var="$3" fn="$4" choices="$5" cur def ans msg
    cur=$(git -C "$root" config --get "himmel.$key" 2>/dev/null) || cur=""
    if [ -n "$cur" ]; then def="$cur"; else def="auto: $(_cm_resolve "$root" "$fn" 2>/dev/null || echo '?')"; fi
    printf '  %s (%s) [%s]: ' "$key" "$choices" "$def"
    ans=""
    IFS= read -r ans || true
    printf '\n'
    ans=$(printf '%s' "$ans" | tr -d '[:space:]')
    if [ -z "$ans" ] || [ "$ans" = "$cur" ]; then return 0; fi
    case "|$choices|" in
        *"|$ans|"*) ;;
        *) echo "  invalid $key '$ans' (expected $choices); kept ${cur:-auto}" >&2; return 0 ;;
    esac
    if ! msg=$(_cm_resolve "$root" "$fn" "$var=$ans" 2>&1 >/dev/null); then
        echo "  ${msg:-project-mode refused $key=$ans}; kept ${cur:-auto}" >&2
        return 0
    fi
    git -C "$root" config "himmel.$key" "$ans" || { echo "  could not write git config himmel.$key" >&2; return 1; }
    echo "  wrote git config himmel.$key=$ans"
}

choose_mode() {
    local root="$1" t f req rc=0
    [ -f "$_CM_LIB" ] || { echo "  choose-mode: resolver missing ($_CM_LIB); skipped" >&2; return 0; }
    _cm_ask "$root" tracker TRACKER project_mode_tracker 'jira|local|none' || rc=1
    _cm_ask "$root" forge FORGE 'project_mode_forge --quiet' 'github|bitbucket|local-git' || rc=1
    t=$(_cm_resolve "$root" project_mode_tracker 2>&1) || { echo "  mode unresolved: $t" >&2; return "$rc"; }
    f=$(_cm_resolve "$root" 'project_mode_forge --quiet' 2>&1) || { echo "  mode unresolved: $f" >&2; return "$rc"; }
    echo "  mode: tracker=$t forge=$f"
    req=$(_cm_resolve "$root" project_mode_id_required 2>/dev/null) || req=1
    if [ "$req" = 0 ]; then
        echo "  tracker=none: commits need no ticket ID locally; set TICKET_ID_REQUIRED=0 in your CI workflow too (docs/configuration.md#tracker-and-forge)"
    fi
    return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ -t 0 ]; then
        choose_mode "${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    else
        echo "  (non-interactive: tracker/forge left as configured; see docs/configuration.md#tracker-and-forge)"
    fi
fi
