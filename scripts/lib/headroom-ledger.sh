#!/usr/bin/env bash
# Headroom ledger append helpers (WS9/HIMMEL-654). The bash twin of
# scripts/telegram/headroom.ts — byte-identical canonical line (AC12/T22) —
# used by the in-hook Claude writer (Task 3). Sources the path resolver.
# bash 3.2-safe (no associative arrays, no mapfile).
#
#   headroom_row <lane> <source> <used_pct> <window> <reset_at> <note> [<ts>]
#     Emits ONE canonical JSON line. tier=null, glm_peak=null (this helper
#     serves the Claude writer, where both are null; GLM/Codex rows are
#     built in TS). v=1; ts=$7 or now-UTC. Empty used_pct/window/reset_at/
#     note -> null.
#   headroom_append <json-line>
#     Appends one line to headroom_ledger_path (atomic single-line O_APPEND,
#     AC0); mkdirs the parent dir on append. Fails soft on an unwritable
#     target (the in-hook caller wraps it `... || true`).
#   CLI: bash headroom-ledger.sh --emit <lane> <source> <used_pct> <window>
#          <reset_at> <note> <ts>
#     Prints one canonical row WITHOUT appending (byte-identical test entry).

_hdr_src="${BASH_SOURCE[0]:-$0}"
_hdr_self_dir=$(cd "$(dirname "$_hdr_src")" 2>/dev/null && pwd) || _hdr_self_dir="$(dirname "$_hdr_src")"
# shellcheck source=headroom-ledger-path.sh
# shellcheck disable=SC1091
. "$_hdr_self_dir/headroom-ledger-path.sh"

# Minimal JSON string escape (matches TS jsonStr): backslash, dquote,
# CR/LF/TAB. bash 3.2-safe parameter expansion.
_hdr_json_str() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '"%s"' "$s"
}

# $1=lane $2=source $3=used_pct(''=null) $4=window(''=null) $5=reset_at(''=null)
# $6=note(''=null) $7=ts(optional, default now UTC)
headroom_row() {
    local lane="${1:-}" source="${2:-}" used_pct="${3:-}" window="${4:-}" reset_at="${5:-}" note="${6:-}" ts="${7:-}"
    [ -n "$ts" ] || ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local j_used j_window j_reset j_note
    if [ -n "$used_pct" ]; then j_used="$used_pct"; else j_used="null"; fi
    if [ -n "$window" ]; then j_window=$(_hdr_json_str "$window"); else j_window="null"; fi
    if [ -n "$reset_at" ]; then j_reset=$(_hdr_json_str "$reset_at"); else j_reset="null"; fi
    if [ -n "$note" ]; then j_note=$(_hdr_json_str "$note"); else j_note="null"; fi
    printf '{"v":1,"ts":%s,"lane":%s,"source":%s,"used_pct":%s,"window":%s,"reset_at":%s,"tier":null,"glm_peak":null,"note":%s}' \
        "$(_hdr_json_str "$ts")" "$(_hdr_json_str "$lane")" "$(_hdr_json_str "$source")" \
        "$j_used" "$j_window" "$j_reset" "$j_note"
}

# $1=json-line. Appends to headroom_ledger_path (atomic single-line O_APPEND).
headroom_append() {
    local line="${1:-}" path dir
    path=$(headroom_ledger_path)
    dir=$(dirname "$path")
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || true
    printf '%s\n' "$line" >> "$path"
}

# CLI entry — only when EXECUTED (not sourced), with --emit.
_hdr_is_main=0
[ "${BASH_SOURCE[0]:-}" = "${0:-}" ] && _hdr_is_main=1
if [ "$_hdr_is_main" = "1" ] && [ "${1:-}" = "--emit" ]; then
    shift
    headroom_row "$@"
    exit 0
fi
