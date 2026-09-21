#!/usr/bin/env bash
# Platform guard (gitbash-only): POSIX bash 3.2+ / Git Bash on Windows, jq +
# sha256sum|shasum only. Twins: provenance.ps1 (PowerShell) and
# scripts/himmelctl/lib/provenance.js (node) write byte-identical rows.
#
# provenance.sh -- the install-provenance ledger writer (HIMMEL-3332 S1).
# SOURCE it (it sets no shell options, defines only prov_* / _prov_* names):
#
#   . "$(dirname "$0")/lib/provenance.sh"
#   prov_begin --writer adopt.sh -- "$@"        # opens a session, exports HIMMEL_PROVENANCE_IID
#   ... the writer does its atomic write ...
#   prov_record replace file "$dest" --pre-file "$snapshot" --backup \
#       --post-file "$dest" --scope project --class code --row adopter-scripts
#   prov_end ok
#
# Format, kinds, write points and rationale: docs/internals/install-provenance.md
# (format reference) and the HIMMEL-3332 design spec (§2). The contract, in short:
#   * one JSON object per line, append-only, at
#     ${HIMMEL_PROVENANCE_DIR:-$HOME/.himmel}/provenance.jsonl
#   * call prov_record AFTER the writer's own write succeeded and BEFORE it
#     prints its success line; the pre-state is captured (and backed up) from
#     bytes/values the writer still holds -- --pre-file names a file holding the
#     PRE bytes (the original, or the writer's own snapshot of it), never the
#     already-overwritten destination.
#   * dry runs (DRY_RUN=1 or --dry-run) write nothing and print
#     "DRY: record <op> <kind> <path>".
#   * a failure returns non-zero with "provenance: ..." on stderr (rc 2 = usage,
#     rc 1 = I/O or missing tool). The caller decides whether that is fatal.
#
# Test seams: HIMMEL_PROVENANCE_NOW (fixed "t"), prov_begin --iid (fixed session).

_PROV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/canon-path.sh
. "$_PROV_LIB_DIR/canon-path.sh"
_PROV_ROOT="$(cd "$_PROV_LIB_DIR/../.." && pwd)"

_prov_err() { printf 'provenance: %s\n' "$*" >&2; }

_prov_need() {
    command -v jq >/dev/null 2>&1 || { _prov_err "jq required"; return 1; }
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
        || { _prov_err "sha256sum or shasum required"; return 1; }
}

_prov_now() {
    if [ -n "${HIMMEL_PROVENANCE_NOW:-}" ]; then printf '%s' "$HIMMEL_PROVENANCE_NOW"
    else date -u +%Y-%m-%dT%H:%M:%SZ; fi
}

_prov_new_iid() {
    printf '%s-%06x' "$(date -u +%Y%m%dT%H%M%SZ)" $(( ((RANDOM << 15) | RANDOM) & 0xffffff ))
}

# prov_dir -- the resolved directory that holds provenance.jsonl and
# provenance-backups/ (HIMMEL_PROVENANCE_DIR wins; else $HOME/.himmel).
prov_dir() {
    local d="${HIMMEL_PROVENANCE_DIR:-}"
    if [ -z "$d" ]; then
        [ -n "${HOME:-}" ] || { _prov_err "HOME is unset and HIMMEL_PROVENANCE_DIR is not given"; return 1; }
        d="$HOME/.himmel"
    fi
    canon_path_partial "$d" || { _prov_err "cannot resolve $d"; return 1; }
}

prov_ledger_path() {
    local d
    d=$(prov_dir) || return 1
    printf '%s/provenance.jsonl' "$d"
}

# _prov_abs_path <path> -- absolute, parent chain resolved (symlinks and Windows
# short names), the basename left as given so a link is recorded as the link.
_prov_abs_path() {
    local p="$1" dir base
    case "$p" in *[\\]*) p=${p//\\//} ;; esac
    case "$p" in /*|[A-Za-z]:/*) ;; *) p="$PWD/$p" ;; esac
    while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    base="${p##*/}"
    dir="${p%/*}"
    [ -n "$dir" ] || dir=/
    dir=$(canon_path_partial "$dir") || return 1
    if [ "$base" = "" ]; then printf '%s' "$dir"; else printf '%s/%s' "${dir%/}" "$base"; fi
}

_prov_sha_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
    else shasum -a 256 | awk '{print $1}'; fi
}

prov_sha_file() { _prov_sha_stdin < "$1"; }
prov_sha_text() { printf '%s' "$1" | _prov_sha_stdin; }

# _prov_json_canon <json> -- `jq -cS` of the value, no trailing newline.
_prov_json_canon() {
    local out
    out=$(printf '%s' "$1" | jq -cS . 2>/dev/null) || return 1
    # A value must be ONE JSON document: jq -c prints one line per document, so
    # '1 2' would otherwise become a two-line "canonical" value and corrupt the row.
    case "$out" in ''|*$'\n'*) return 1 ;; esac
    printf '%s' "$out"
}

# prov_sha_json <json> -- sha256 of the canonical (`jq -cS`) bytes of a value.
prov_sha_json() {
    local c
    c=$(_prov_json_canon "$1") || { _prov_err "not valid JSON: $1"; return 1; }
    prov_sha_text "$c"
}

_prov_size() { wc -c < "$1" | tr -d ' '; }

# _prov_mode <file> -- four-digit octal ("0644"), GNU stat first, then BSD.
_prov_mode() {
    local m
    m=$(stat -c %a "$1" 2>/dev/null) || m=$(stat -f %Lp "$1" 2>/dev/null) || return 1  # gnu-ok: BSD stat -f paired on the same line
    while [ "${#m}" -lt 4 ]; do m="0$m"; done
    printf '%s' "$m"
}

_prov_platform() {
    case "$(uname -s 2>/dev/null)" in
        Linux) printf 'linux' ;;
        Darwin) printf 'darwin' ;;
        MINGW*|MSYS*|CYGWIN*) printf 'win32' ;;
        *) uname -s | tr '[:upper:]' '[:lower:]' ;;
    esac
}

# _prov_append <line> -- one O_APPEND write; a torn last line (no newline) is
# closed first so it costs one row, not two.
_prov_append() {
    local dir ledger
    dir=$(prov_dir) || return 1
    ledger="$dir/provenance.jsonl"
    ( umask 077; mkdir -p "$dir" ) || { _prov_err "cannot create $dir"; return 1; }
    if [ -s "$ledger" ] && [ -n "$(tail -c1 "$ledger")" ]; then
        ( umask 077; printf '\n' >> "$ledger" ) || return 1
    fi
    ( umask 077; printf '%s\n' "$1" >> "$ledger" ) || { _prov_err "cannot append to $ledger"; return 1; }
}

# _prov_json_or_null <string> -- a JSON string, or null when empty.
_prov_str_or_null() { if [ -n "$1" ]; then jq -nc --arg v "$1" '$v'; else printf 'null'; fi; }

# _prov_begin_row <iid> <writer> <target> <root> <argv-json>
_prov_begin_row() {
    local iid="$1" writer="$2" target="$3" root="$4" argv="$5" head="" version="" home cfg
    head=$(git -C "$root" rev-parse HEAD 2>/dev/null) || head=""
    [ -f "$root/VERSION" ] && version=$(tr -d ' \r\n' < "$root/VERSION")
    home=$(canon_path_native "${HOME:-}" 2>/dev/null) || home="${HOME:-}"
    cfg=$(canon_path_partial "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}" 2>/dev/null) || cfg="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
    jq -nc --arg t "$(_prov_now)" --arg iid "$iid" --arg root "$root" \
        --argjson head "$(_prov_str_or_null "$head")" \
        --argjson version "$(_prov_str_or_null "$version")" \
        --argjson argv "$argv" --arg home "$home" --arg cfg "$cfg" \
        --argjson target "$(_prov_str_or_null "$target")" \
        --arg platform "$(_prov_platform)" \
        --argjson writer "$(_prov_str_or_null "$writer")" \
        '{t:$t,iid:$iid,op:"install-begin",himmel_root:$root,himmel_head:$head,version:$version,argv:$argv,home:$home,claude_config_dir:$cfg,target:$target,platform:$platform,writer:$writer}'
}

_prov_dry() { [ "${DRY_RUN:-0}" = "1" ]; }

# prov_begin [--writer W] [--target T] [--root R] [--iid ID] [--dry-run] [--] [argv...]
# Opens a session: writes install-begin and exports HIMMEL_PROVENANCE_IID so
# every child process appends into it. A no-op when a session is already
# exported (this process is somebody's child) unless --iid is given.
prov_begin() {
    local writer="" target="" root="$_PROV_ROOT" iid="" dry=0 argv='[]' a
    while [ $# -gt 0 ]; do
        case "$1" in
            --writer) [ $# -ge 2 ] || { _prov_err "prov_begin: --writer needs a value"; return 2; }; writer="$2"; shift 2 ;;
            --target) [ $# -ge 2 ] || { _prov_err "prov_begin: --target needs a value"; return 2; }; target="$2"; shift 2 ;;
            --root)   [ $# -ge 2 ] || { _prov_err "prov_begin: --root needs a value"; return 2; }; root="$2"; shift 2 ;;
            --iid)    [ $# -ge 2 ] || { _prov_err "prov_begin: --iid needs a value"; return 2; }; iid="$2"; shift 2 ;;
            --dry-run) dry=1; shift ;;
            --) shift; break ;;
            *) _prov_err "prov_begin: unknown option $1"; return 2 ;;
        esac
    done
    if [ "$dry" = 1 ] || _prov_dry; then return 0; fi
    _prov_need || return 1
    if [ -z "$iid" ]; then
        [ -z "${HIMMEL_PROVENANCE_IID:-}" ] || return 0
        iid=$(_prov_new_iid)
    fi
    for a in "$@"; do argv=$(jq -nc --argjson acc "$argv" --arg v "$a" '$acc + [$v]') || return 1; done
    [ -n "$target" ] && target=$(_prov_abs_path "$target" 2>/dev/null || printf '%s' "$target")
    _prov_append "$(_prov_begin_row "$iid" "$writer" "$target" "$root" "$argv")" || return 1
    HIMMEL_PROVENANCE_IID="$iid"
    _PROV_OWNS="$iid"
    export HIMMEL_PROVENANCE_IID
}

# _prov_end_row <iid> <status> <failed-step>
_prov_end_row() {
    jq -nc --arg t "$(_prov_now)" --arg iid "$1" --arg status "$2" \
        --argjson step "$(_prov_str_or_null "$3")" \
        '{t:$t,iid:$iid,op:"install-end",status:$status,failed_step:$step}'
}

# prov_end <ok|failed|partial> [failed-step] -- closes the session THIS process
# opened; a no-op for a child that only inherited the session id.
prov_end() {
    local status="${1-}" step="${2-}" iid="${HIMMEL_PROVENANCE_IID:-}"
    case "$status" in ok|failed|partial) ;; *) _prov_err "prov_end: status must be ok|failed|partial"; return 2 ;; esac
    _prov_dry && return 0
    [ -n "$iid" ] && [ "${_PROV_OWNS:-}" = "$iid" ] || return 0
    _prov_need || return 1
    # close ownership only once the end row is on disk, so a failed append can be retried
    _prov_append "$(_prov_end_row "$iid" "$status" "$step")" || return 1
    unset HIMMEL_PROVENANCE_IID _PROV_OWNS
}

# _prov_body <side> <kind> <src-type> <src-val> -- the sha/size/mode (files) /
# sha (json-key, json-elem, text) / value (registrations) fragment.
_prov_body() {
    local kind="$2" stype="$3" sval="$4" sha size mode c
    case "$stype" in
        file)
            [ -f "$sval" ] || { _prov_err "not a file: $sval"; return 1; }
            sha=$(prov_sha_file "$sval") && size=$(_prov_size "$sval") && mode=$(_prov_mode "$sval") || return 1
            jq -nc --arg sha "$sha" --argjson size "$size" --arg mode "$mode" '{sha:$sha,size:$size,mode:$mode}'
            ;;
        text)
            jq -nc --arg sha "$(prov_sha_text "$sval")" '{sha:$sha}'
            ;;
        json)
            c=$(_prov_json_canon "$sval") || { _prov_err "not valid JSON: $sval"; return 1; }
            case "$kind" in
                json-key|json-elem) jq -nc --arg sha "$(prov_sha_text "$c")" '{sha:$sha}' ;;
                *) jq -nc --argjson v "$c" '{value:$v}' ;;
            esac
            ;;
    esac
}

# _prov_backup <iid> <unit-path> <src-type> <src-val> -- copy the pre-state into
# provenance-backups/<iid>/<seq>-<basename>[.prior.json|.prior.txt]; prints the path.
_prov_backup() {
    local iid="$1" upath="$2" stype="$3" sval="$4" dir bdir n name dest c _f
    dir=$(prov_dir) || return 1
    bdir="$dir/provenance-backups/$iid"
    ( umask 077; mkdir -p "$bdir" ) || { _prov_err "cannot create $bdir"; return 1; }
    n=1; for _f in "$bdir"/*; do [ -e "$_f" ] && n=$((n + 1)); done
    while :; do
        name=$(printf '%03d-%s' "$n" "${upath##*/}")
        case "$stype" in json) name="$name.prior.json" ;; text) name="$name.prior.txt" ;; esac
        dest="$bdir/$name"
        # reserve the name atomically (noclobber = O_EXCL) so two writers sharing
        # an iid cannot both pick the same sequence number
        ( umask 077; set -C; : > "$dest" ) 2>/dev/null && break
        n=$((n + 1))
    done
    case "$stype" in
        file) cp -p "$sval" "$dest" ;;
        json) c=$(_prov_json_canon "$sval") && ( umask 077; printf '%s' "$c" > "$dest" ) ;;
        text) ( umask 077; printf '%s' "$sval" > "$dest" ) ;;
    esac || { _prov_err "cannot write backup $dest"; return 1; }
    printf '%s' "$dest"
}

_PROV_OPS=" create replace insert append register link noop "
_PROV_KINDS=" file tree json-key json-elem block line plugin marketplace job unit shim symlink git-hook mcp collection tool "
_PROV_RESERVED=" t iid op kind path unit scope class pre post writer manifest_row "

# prov_record <op> <kind> <path|-> [flags]   -- append one artifact row.
#   --unit U  --scope user|project|clone|machine  --class code|state|keep
#   --row ID (manifest_row)  --writer W  --field KEY=JSON (repeatable, e.g.
#   --field container_created=true  --field preexisted=false)
#   --pre-absent | --pre-file F | --pre-json V | --pre-text S
#   --post-file F | --post-json V | --post-text S
#   --backup (copy the pre-state into the backups dir)   --dry-run
# <path> "-" means no path (registrations). Row key order:
#   t iid op kind path unit scope class <--field keys in call order> pre post writer manifest_row
prov_record() {
    [ $# -ge 3 ] || { _prov_err "prov_record: usage: prov_record <op> <kind> <path|-> [flags]"; return 2; }
    local op="$1" kind="$2" path="$3" unit="" scope="" class="" row="" writer=""
    local pre_t="" pre_v="" post_t="" post_v="" backup=0 dry=0 fields='{}' k v cpath="" iid implicit=0
    local pre='null' post='null' bk='null' body
    shift 3
    case "$_PROV_OPS" in *" $op "*) ;; *) _prov_err "prov_record: unknown op '$op'"; return 2 ;; esac
    case "$_PROV_KINDS" in *" $kind "*) ;; *) _prov_err "prov_record: unknown kind '$kind'"; return 2 ;; esac
    while [ $# -gt 0 ]; do
        case "$1" in
            --backup) backup=1; shift; continue ;;
            --dry-run) dry=1; shift; continue ;;
            --pre-absent) pre_t=absent; pre_v=""; shift; continue ;;
        esac
        [ $# -ge 2 ] || { _prov_err "prov_record: $1 needs a value"; return 2; }
        case "$1" in
            --unit) unit="$2" ;;
            --scope)
                case "$2" in user|project|clone|machine) scope="$2" ;; *) _prov_err "prov_record: bad scope '$2'"; return 2 ;; esac ;;
            --class)
                case "$2" in code|state|keep) class="$2" ;; *) _prov_err "prov_record: bad class '$2'"; return 2 ;; esac ;;
            --row) row="$2" ;;
            --writer) writer="$2" ;;
            --field)
                k="${2%%=*}"; v="${2#*=}"
                case "$2" in *=*) ;; *) _prov_err "prov_record: --field wants KEY=JSON"; return 2 ;; esac
                case "$k" in ""|[!a-z_]*|*[!a-z0-9_]*) _prov_err "prov_record: bad field key '$k'"; return 2 ;; esac
                case "$_PROV_RESERVED" in *" $k "*) _prov_err "prov_record: field key '$k' is reserved"; return 2 ;; esac
                v=$(_prov_json_canon "$v") || { _prov_err "prov_record: --field $k is not valid JSON"; return 2; }
                fields=$(jq -nc --argjson acc "$fields" --arg k "$k" --argjson v "$v" '$acc + {($k): $v}') || return 1 ;;
            --pre-file) pre_t='file'; pre_v="$2" ;;
            --pre-json) pre_t=json; pre_v="$2" ;;
            --pre-text) pre_t=text; pre_v="$2" ;;
            --post-file) post_t='file'; post_v="$2" ;;
            --post-json) post_t=json; post_v="$2" ;;
            --post-text) post_t=text; post_v="$2" ;;
            *) _prov_err "prov_record: unknown option $1"; return 2 ;;
        esac
        shift 2
    done
    if [ "$backup" = 1 ]; then
        case "$pre_t" in file|json|text) ;; *) _prov_err "prov_record: --backup needs --pre-file, --pre-json or --pre-text"; return 2 ;; esac
    fi
    if [ "$dry" = 1 ] || _prov_dry; then
        printf 'DRY: record %s %s %s\n' "$op" "$kind" "$path"
        return 0
    fi
    _prov_need || return 1

    iid="${HIMMEL_PROVENANCE_IID:-}"
    if [ -z "$iid" ]; then implicit=1; iid=$(_prov_new_iid); fi
    if [ "$path" != "-" ] && [ -n "$path" ]; then cpath=$(_prov_abs_path "$path") || { _prov_err "cannot resolve $path"; return 1; }; fi

    # pre-state, then its backup (both before anything is appended)
    if [ "$pre_t" = absent ]; then
        pre='{"state":"absent"}'
    elif [ -n "$pre_t" ]; then
        body=$(_prov_body pre "$kind" "$pre_t" "$pre_v") || return 1
        if [ "$backup" = 1 ]; then
            bk=$(_prov_backup "$iid" "${cpath:-${unit:-unit}}" "$pre_t" "$pre_v") || return 1
            bk=$(jq -nc --arg v "$bk" '$v')
        fi
        pre=$(jq -nc --argjson b "$body" --argjson bk "$bk" '{state:"present"} + $b + {backup:$bk}') || return 1
    fi
    if [ -n "$post_t" ]; then post=$(_prov_body post "$kind" "$post_t" "$post_v") || return 1; fi

    [ "$implicit" = 1 ] && { _prov_append "$(_prov_begin_row "$iid" "$writer" "" "$_PROV_ROOT" '[]')" || return 1; }
    _prov_append "$(jq -nc --arg t "$(_prov_now)" --arg iid "$iid" --arg op "$op" --arg kind "$kind" \
        --arg path "$cpath" --arg unit "$unit" --arg scope "$scope" --arg class "$class" \
        --argjson fields "$fields" --argjson pre "$pre" --argjson post "$post" \
        --arg writer "$writer" --arg row "$row" \
        '{t:$t,iid:$iid,op:$op,kind:$kind}
         + (if $path != "" then {path:$path} else {} end)
         + (if $unit != "" then {unit:$unit} else {} end)
         + (if $scope != "" then {scope:$scope} else {} end)
         + (if $class != "" then {class:$class} else {} end)
         + $fields
         + (if $pre != null then {pre:$pre} else {} end)
         + (if $post != null then {post:$post} else {} end)
         + (if $writer != "" then {writer:$writer} else {} end)
         + (if $row != "" then {manifest_row:$row} else {} end)')" || return 1
    if [ "$implicit" = 1 ]; then _prov_append "$(_prov_end_row "$iid" ok "")" || return 1; fi
}
