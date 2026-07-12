#!/usr/bin/env bash
# Quota-gauge ledger append helpers (WS9/HIMMEL-654). The bash twin of
# scripts/telegram/quota-gauge.ts — byte-identical canonical line (AC12/T22) —
# used by the in-hook Claude writer (Task 3). Sources the path resolver.
# bash 3.2-safe (no associative arrays, no mapfile).
#
#   quota_gauge_row <lane> <source> <used_pct> <window> <reset_at> <note> [<ts>]
#     Emits ONE canonical JSON line. tier=null, glm_peak=null (this helper
#     serves the Claude writer, where both are null; GLM/Codex rows are
#     built in TS). v=1; ts=$7 or now-UTC. Empty used_pct/window/reset_at/
#     note -> null.
#   quota_gauge_append <json-line>
#     Appends one line to quota_gauge_ledger_path (atomic single-line O_APPEND,
#     AC0); mkdirs the parent dir on append. Fails soft on an unwritable
#     target (the in-hook caller wraps it `... || true`).
#   CLI: bash quota-gauge-ledger.sh --emit <lane> <source> <used_pct> <window>
#          <reset_at> <note> <ts>
#     Prints one canonical row WITHOUT appending (byte-identical test entry).

_qg_src="${BASH_SOURCE[0]:-$0}"
_qg_self_dir=$(cd "$(dirname "$_qg_src")" 2>/dev/null && pwd) || _qg_self_dir="$(dirname "$_qg_src")"
# shellcheck source=quota-gauge-ledger-path.sh
# shellcheck disable=SC1091
. "$_qg_self_dir/quota-gauge-ledger-path.sh"

# Minimal JSON string escape (matches TS jsonStr): backslash, dquote,
# CR/LF/TAB. bash 3.2-safe parameter expansion.
_qg_json_str() {
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
quota_gauge_row() {
    local lane="${1:-}" source="${2:-}" used_pct="${3:-}" window="${4:-}" reset_at="${5:-}" note="${6:-}" ts="${7:-}"
    [ -n "$ts" ] || ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local j_used j_window j_reset j_note
    if [ -n "$used_pct" ]; then j_used="$used_pct"; else j_used="null"; fi
    if [ -n "$window" ]; then j_window=$(_qg_json_str "$window"); else j_window="null"; fi
    if [ -n "$reset_at" ]; then j_reset=$(_qg_json_str "$reset_at"); else j_reset="null"; fi
    if [ -n "$note" ]; then j_note=$(_qg_json_str "$note"); else j_note="null"; fi
    printf '{"v":1,"ts":%s,"lane":%s,"source":%s,"used_pct":%s,"window":%s,"reset_at":%s,"tier":null,"glm_peak":null,"note":%s}' \
        "$(_qg_json_str "$ts")" "$(_qg_json_str "$lane")" "$(_qg_json_str "$source")" \
        "$j_used" "$j_window" "$j_reset" "$j_note"
}

# $1=json-line. Appends to quota_gauge_ledger_path (atomic single-line O_APPEND).
quota_gauge_append() {
    local line="${1:-}" path dir
    path=$(quota_gauge_ledger_path)
    dir=$(dirname "$path")
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || true
    printf '%s\n' "$line" >> "$path"
}

# CLI entry — only when EXECUTED (not sourced), with --emit.
_qg_is_main=0
[ "${BASH_SOURCE[0]:-}" = "${0:-}" ] && _qg_is_main=1
if [ "$_qg_is_main" = "1" ] && [ "${1:-}" = "--emit" ]; then
    shift
    quota_gauge_row "$@"
    exit 0
fi
