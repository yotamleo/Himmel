#!/usr/bin/env bash
# Platform guard (gitbash-only): POSIX bash 3.2+ / Git Bash on Windows, jq only.
#
# provenance-identity.sh -- the live-identity reader for register-kind
# provenance units (HIMMEL-3525 S16, design HIMMEL-3525-register-identity.md
# §2-§3). One function answers "what is registered under this name right now":
#
#   prov_identity_live <kind> <unit-json>
#       stdout: a 64-hex token | ABSENT | UNREADABLE ; rc 0
#       rc 2, no output: this kind has no reader (the caller treats the row
#       as legacy)
#
# The token is prov_sha_text "<kind>\n<canonical identity>". The SAME reader
# runs at install (a read-back straight after the registration succeeds; the
# writer records the token with --post-text + --field identity_v=1) and at
# uninstall (prov_read_verdict), so the two sides cannot drift apart. ABSENT =
# the registrar answered and the name is not registered; UNREADABLE = the
# registrar could not be asked, never treated as absent or as a match.
#
# S16 shipped the collection reader; S17 adds plugin/marketplace. job (S18)
# still returns rc 2 until its slice lands.
#
# SOURCE it; it defines only prov_identity_* / _provid_* names and sets no
# shell options. The reader for collection calls qmd_cmd, sourcing
# qmd-bin.sh on first use when the caller has not already.

# guard double-source
# shellcheck disable=SC2317  # the exit is reached only when EXECUTED rather than sourced
if [ -n "${_PROV_IDENTITY_LIB_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_PROV_IDENTITY_LIB_LOADED=1

_PROVID_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/provenance.sh
declare -F prov_sha_text >/dev/null 2>&1 || . "$_PROVID_LIB_DIR/provenance.sh"

# _provid_canon_path <path> -- the physical absolute path when the directory
# exists, else the path exactly as given. Both sides of the comparison call it.
_provid_canon_path() {
    local p="$1" c
    if [ -n "$p" ] && [ -d "$p" ] && c=$(cd -P -- "$p" 2>/dev/null && pwd -P) && [ -n "$c" ]; then
        printf '%s' "$c"
    else
        printf '%s' "$p"
    fi
}

# _provid_token <kind> <canonical> -- the identity token.
_provid_token() { prov_sha_text "$1"$'\n'"$2"; }

# _provid_cache_dir -- the per-run cache dir beside the fold file, created on
# first use; prov_read_cleanup removes it. No fold (the install side) means no
# cache: rc 1, and every call asks the registrar.
_provid_cache_dir() {
    [ -n "${PROV_READ_FOLD:-}" ] || return 1
    local d="$PROV_READ_FOLD.identity.d"
    [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || return 1
    printf '%s' "$d"
}

# _provid_qmd_show <name> -- sets _PROVID_STATE (ok|ABSENT|UNREADABLE),
# _PROVID_PATH and _PROVID_PATTERN from `qmd collection show <name>` (qmd's
# public CLI; its index.yml is private and never parsed). A successful read or
# an ABSENT is cached for the run; an UNREADABLE is not, so it is retried.
_provid_qmd_show() {
    local name="$1" out rc cache="" key
    _PROVID_STATE=UNREADABLE _PROVID_PATH="" _PROVID_PATTERN=""
    [ -n "$name" ] || return 0
    if cache=$(_provid_cache_dir); then
        key=$(prov_sha_text "collection"$'\n'"$name") || key=""
        [ -n "$key" ] && cache="$cache/collection.$key" || cache=""
    else
        cache=""
    fi
    if [ -n "$cache" ] && [ -f "$cache" ]; then
        out=$(cat "$cache"); rc=0
    else
        if ! declare -F qmd_cmd >/dev/null 2>&1; then
            # shellcheck source=scripts/lib/qmd-bin.sh
            . "$_PROVID_LIB_DIR/qmd-bin.sh" || return 0
        fi
        out=$(qmd_cmd collection show "$name" 2>&1); rc=$?
        if [ "$rc" -ne 0 ]; then
            case "$out" in
                *"Collection not found: $name"*) out="ABSENT"; rc=0 ;;
                *) return 0 ;;
            esac
        fi
        [ -n "$cache" ] && printf '%s' "$out" > "$cache" 2>/dev/null
    fi
    if [ "$out" = "ABSENT" ]; then _PROVID_STATE=ABSENT; return 0; fi
    local line val
    while IFS= read -r line; do
        line=${line%$'\r'}
        case "$line" in
            *[![:space:]]*) ;;
            *) continue ;;
        esac
        val=${line#"${line%%[![:space:]]*}"}
        case "$val" in
            Path:*)    val=${val#Path:};    _PROVID_PATH=${val#"${val%%[![:space:]]*}"} ;;
            Pattern:*) val=${val#Pattern:}; _PROVID_PATTERN=${val#"${val%%[![:space:]]*}"} ;;
        esac
    done <<EOF
$out
EOF
    if [ -n "$_PROVID_PATH" ]; then _PROVID_STATE=ok
    elif [ -n "$cache" ]; then rm -f "$cache"
    fi
    return 0
}

# _provid_collection <unit-json> -- identity = name, canonical path, pattern.
_provid_collection() {
    local name
    name=$(printf '%s' "$1" | jq -r '.unit // ""' 2>/dev/null) || name=""
    _provid_qmd_show "$name"
    case "$_PROVID_STATE" in
        ok) _provid_token collection "$name"$'\n'"$(_provid_canon_path "$_PROVID_PATH")"$'\n'"$_PROVID_PATTERN" \
                || printf 'UNREADABLE' ;;
        *)  printf '%s' "$_PROVID_STATE" ;;
    esac
}

# _provid_cfg_dir -- resolves the Claude config dir the same way
# install-plugins.sh does (PROV_CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"),
# independently -- uninstall.sh never sets either var itself.
_provid_cfg_dir() {
    printf '%s' "${PROV_CFG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
}

# _provid_marketplace <unit-json> -- identity = name + canonical source
# object from known_marketplaces.json[name].source (design §3.2): installLocation/
# lastUpdated/autoUpdate excluded. A directory source's path is canonicalized;
# other source shapes are taken as the CLI stores them, keys sorted.
_provid_marketplace() {
    local name file src stype spath
    name=$(printf '%s' "$1" | jq -r '.unit // ""' 2>/dev/null) || name=""
    [ -n "$name" ] || { printf 'UNREADABLE'; return 0; }
    file="$(_provid_cfg_dir)/plugins/known_marketplaces.json"
    [ -f "$file" ] || { printf 'ABSENT'; return 0; }
    src=$(jq -c --arg n "$name" '.[$n].source // null' "$file" 2>/dev/null) || { printf 'UNREADABLE'; return 0; }
    [ "$src" = "null" ] && { printf 'ABSENT'; return 0; }
    stype=$(printf '%s' "$src" | jq -r '.source // ""')
    if [ "$stype" = "directory" ]; then
        spath=$(printf '%s' "$src" | jq -r '.path // ""')
        src=$(printf '%s' "$src" | jq -c --arg p "$(_provid_canon_path "$spath")" '.path = $p') || { printf 'UNREADABLE'; return 0; }
    fi
    src=$(printf '%s' "$src" | jq -cS '.') || { printf 'UNREADABLE'; return 0; }
    _provid_token marketplace "$name"$'\n'"$src" || printf 'UNREADABLE'
}

# _provid_plugin <unit-json> -- identity = id, cli_scope, project_path (for
# project/local scope), and the marketplace's own LIVE identity token (design
# §3.3): a marketplace re-pointed at a new source changes every plugin it
# owns too, folded in with no separate cascade logic. Unit fields consumed:
# .unit (id, "name@marketplace"), .fields.cli_scope, .fields.project_path,
# .fields.marketplace (the marketplace name).
_provid_plugin() {
    local u="$1" id scope proj mkt file version entry mkt_live
    id=$(printf '%s' "$u" | jq -r '.unit // ""' 2>/dev/null) || id=""
    scope=$(printf '%s' "$u" | jq -r '.fields.cli_scope // ""' 2>/dev/null) || scope=""
    proj=$(printf '%s' "$u" | jq -r '.fields.project_path // ""' 2>/dev/null) || proj=""
    mkt=$(printf '%s' "$u" | jq -r '.fields.marketplace // ""' 2>/dev/null) || mkt=""
    if [ -z "$id" ] || [ -z "$scope" ]; then printf 'UNREADABLE'; return 0; fi
    file="$(_provid_cfg_dir)/plugins/installed_plugins.json"
    [ -f "$file" ] || { printf 'ABSENT'; return 0; }
    version=$(jq -r '.version // ""' "$file" 2>/dev/null) || { printf 'UNREADABLE'; return 0; }
    [ "$version" = "2" ] || { printf 'UNREADABLE'; return 0; }
    entry=$(jq -c --arg id "$id" --arg s "$scope" --arg p "$(_provid_canon_path "$proj")" '
        (.plugins[$id] // []) | map(select(.scope == $s and
            (($s != "project" and $s != "local") or (.projectPath // "") == $p)))
        | .[0] // null
    ' "$file" 2>/dev/null) || { printf 'UNREADABLE'; return 0; }
    [ "$entry" = "null" ] && { printf 'ABSENT'; return 0; }
    mkt_live=$(_provid_marketplace "$(jq -nc --arg n "$mkt" '{unit:$n}')")
    _provid_token plugin "$id"$'\n'"$scope"$'\n'"$proj"$'\n'"$mkt_live" || printf 'UNREADABLE'
}

# prov_identity_live <kind> <unit-json> -- see the header.
prov_identity_live() {
    case "$1" in
        collection)  _provid_collection "$2" ;;
        marketplace) _provid_marketplace "$2" ;;
        plugin)      _provid_plugin "$2" ;;
        *) return 2 ;;
    esac
}
