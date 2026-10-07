#!/usr/bin/env bash
# project-mode.sh — the one owner of "which tracker, which forge" (HIMMEL-4758,
# HIMMEL-4748 spec section 1). Source it, then call a project_mode_* function.
# Each prints its answer on stdout; an invalid or contradictory setting prints
# one line on stderr and returns 2. scripts/lib/project-mode.mjs is the JS twin;
# both are pinned to fixtures/project-modes.tsv and fixtures/forge-origins.tsv.
#
#   project_mode_tracker            jira | local | none
#       TRACKER env > git config himmel.tracker > detection (jira when
#       JIRA_PROJECT_KEY is set, else local). Jira credentials are never read.
#   project_mode_forge [--for-guard] github | bitbucket | local-git | none
#       FORGE env > git config himmel.forge > detection from the origin HOST
#       (github.com / bitbucket.org or a subdomain; any other origin, or none,
#       inside a work tree is local-git; outside a work tree, none).
#       I8: local-git is refused on a github.com / bitbucket.org origin.
#       --for-guard reads detection only, so no env or config can steer it.
#   project_mode_id_pattern         ERE a commit subject must match ('' = none)
#   project_mode_id_required        TICKET_ID_REQUIRED verbatim, else 0 for
#                                   tracker none, else 1
#   project_mode_phases             the leg phase set for the forge
#   project_mode_env                all four as ONE TAB-separated line:
#       TRACKER=..<TAB>FORGE=..<TAB>TICKET_ID_REQUIRED=..<TAB>TICKET_ID_PATTERN=..
#
# Standalone on purpose: it does not source forge.sh, so adopt.sh ships one
# file beside check-commit-msg.sh. _project_mode_origin_host mirrors
# forge.sh's _forge_origin_host; test-project-mode.sh walks forge-origins.tsv
# to keep the two in step. Bash 3.2-safe.

# _project_mode_origin_host <url> — the lowercased HOST of a git remote URL,
# empty for a local path. Same rules as forge.sh _forge_origin_host.
_project_mode_origin_host() {
    local u rest authority scheme
    u=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    scheme="${u%%://*}"
    authority=""
    case "$u" in
        *://*)
            case "$scheme" in
                ''|*[!a-z0-9+.-]*) ;;
                *) rest="${u#*://}"; authority="${rest%%/*}" ;;
            esac
            ;;
    esac
    if [ -z "$authority" ]; then
        case "${u%%/*}" in
            *:*) authority="${u%%:*}" ;;
        esac
    fi
    authority="${authority##*@}"
    authority="${authority%%:*}"
    printf '%s' "${authority%.}"
}

# _project_mode_detect_forge [quiet] — detection only (no env, no config).
_project_mode_detect_forge() {
    local origin host
    if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
        printf 'none\n'
        return 0
    fi
    origin=$(git remote get-url origin 2>/dev/null) || origin=""
    host=$(_project_mode_origin_host "$origin")
    case "$host" in
        github.com|*.github.com)       printf 'github\n' ;;
        bitbucket.org|*.bitbucket.org) printf 'bitbucket\n' ;;
        *)
            if [ -n "$origin" ] && [ "${1:-}" != quiet ]; then
                echo "project-mode: origin ($origin) is neither github.com nor bitbucket.org — forge is local-git (set FORGE or git config himmel.forge to choose)" >&2
            fi
            printf 'local-git\n'
            ;;
    esac
}

project_mode_tracker() {
    local t src
    if [ -n "${TRACKER:-}" ]; then
        t="$TRACKER"; src="TRACKER"
    else
        t=$(git config --get himmel.tracker 2>/dev/null) || t=""
        src="git config himmel.tracker"
    fi
    if [ -z "$t" ]; then
        if [ -n "${JIRA_PROJECT_KEY:-}" ]; then printf 'jira\n'; else printf 'local\n'; fi
        return 0
    fi
    case "$t" in
        jira)
            if [ -z "${JIRA_PROJECT_KEY:-}" ]; then
                echo "project-mode: $src=jira but JIRA_PROJECT_KEY is not set — set it, or choose TRACKER=local|none" >&2
                return 2
            fi
            ;;
        local|none) ;;
        *)
            echo "project-mode: invalid $src='$t' (expected jira|local|none)" >&2
            return 2
            ;;
    esac
    printf '%s\n' "$t"
}

project_mode_forge() {
    local quiet="" f src detected
    if [ "${1:-}" = --for-guard ]; then
        _project_mode_detect_forge quiet
        return 0
    fi
    [ "${1:-}" = --quiet ] && quiet=quiet
    if [ -n "${FORGE:-}" ]; then
        f="$FORGE"; src="FORGE"
        case "$f" in
            github|bitbucket|local-git|none) ;;
            *) echo "project-mode: invalid FORGE='$f' (expected github|bitbucket|local-git|none)" >&2; return 2 ;;
        esac
    else
        f=$(git config --get himmel.forge 2>/dev/null) || f=""
        src="git config himmel.forge"
        case "$f" in
            '') _project_mode_detect_forge $quiet; return 0 ;;
            github|bitbucket|local-git) ;;
            *) echo "project-mode: invalid $src='$f' (expected github|bitbucket|local-git)" >&2; return 2 ;;
        esac
    fi
    if [ "$f" = local-git ]; then
        detected=$(_project_mode_detect_forge quiet)
        case "$detected" in
            github|bitbucket)
                echo "project-mode: $src=local-git refused — origin is $([ "$detected" = github ] && echo github.com || echo bitbucket.org); local-git is never selected on a hosted origin (I8)" >&2
                return 2
                ;;
        esac
    fi
    printf '%s\n' "$f"
}

project_mode_id_pattern() {
    local t key prefix nl='
'
    if [ -n "${TICKET_ID_PATTERN:-}" ]; then
        # One line only: project_mode_env carries it on one line, and grep -E
        # would read a newline as an alternative the hook never sees.
        case "$TICKET_ID_PATTERN" in
            *"$nl"*)
                echo "project-mode: TICKET_ID_PATTERN is multi-line (expected one ERE; join alternatives with |)" >&2
                return 2
                ;;
        esac
        printf '%s\n' "$TICKET_ID_PATTERN"
        return 0
    fi
    t=$(project_mode_tracker) || return 2
    case "$t" in
        jira)
            # Escape ERE metacharacters so a key like `A.B` matches literally.
            key=$(printf '%s' "$JIRA_PROJECT_KEY" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
            printf '%s-[0-9]+\n' "$key"
            ;;
        local)
            prefix=$(git config --get himmel.trackerPrefix 2>/dev/null) || prefix=""
            [ -n "$prefix" ] || prefix=LOCAL
            case "$prefix" in
                [A-Z]*) ;;
                *) prefix="" ;;
            esac
            case "$prefix" in
                ''|*[!A-Z0-9]*)
                    echo "project-mode: invalid git config himmel.trackerPrefix (expected an uppercase letter, then A-Z/0-9)" >&2
                    return 2
                    ;;
            esac
            printf '(^|[^0-9A-Za-z_])(#|%s-)[0-9]+([^0-9A-Za-z_]|$)\n' "$prefix"
            ;;
        none) printf '\n' ;;
    esac
}

project_mode_id_required() {
    local t
    if [ -n "${TICKET_ID_REQUIRED:-}" ]; then
        # A newline or TAB would split project_mode_env's one line and drop
        # the pattern after it: refuse, as the bare value was refused before.
        case "$TICKET_ID_REQUIRED" in
            *"
"*|*"	"*)
                echo "project-mode: TICKET_ID_REQUIRED carries a newline or TAB (expected 1|0)" >&2
                return 2
                ;;
        esac
        printf '%s\n' "$TICKET_ID_REQUIRED"
        return 0
    fi
    t=$(project_mode_tracker) || return 2
    if [ "$t" = none ]; then printf '0\n'; else printf '1\n'; fi
}

project_mode_phases() {
    local f
    f=$(project_mode_forge) || return 2
    case "$f" in
        github|bitbucket) printf 'LIVE PR-OPEN CI READY GO MERGED WRAPPED\n' ;;
        local-git)        printf 'LIVE READY GO MERGED WRAPPED\n' ;;
        none)             printf 'LIVE READY WRAPPED\n' ;;
    esac
}

project_mode_env() {
    local t f r p
    t=$(project_mode_tracker) || return 2
    f=$(project_mode_forge --quiet) || return 2
    r=$(project_mode_id_required) || return 2
    p=$(project_mode_id_pattern) || return 2
    printf 'TRACKER=%s\tFORGE=%s\tTICKET_ID_REQUIRED=%s\tTICKET_ID_PATTERN=%s\n' "$t" "$f" "$r" "$p"
}
