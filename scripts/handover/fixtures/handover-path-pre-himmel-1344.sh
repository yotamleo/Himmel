#!/usr/bin/env bash
# Test-owned partial-deployment fixture. It deliberately provides the resolver
# and JSON helper contract that arm-resume.sh / queue-lock.sh already depended
# on before HIMMEL-1344, but no HIMMEL-1344 identity or record-matcher helpers.

handover_root() {
    if [ -n "${HANDOVER_DIR:-}" ] && [ -d "$HANDOVER_DIR" ]; then
        ( cd "$HANDOVER_DIR" && pwd )
        return 0
    fi
    return 2
}

handover_root_ensure() {
    handover_root
}

_HP_ESC=""
_hp_json_escape() {
    _HP_ESC="${1//\\/\\\\}"
    _HP_ESC="${_HP_ESC//\"/\\\"}"
}

_HP_FIELD=""
_hp_json_field() {
    local _hp_rest _hp_chunk _hp_bs
    _HP_FIELD=""
    case "$1" in
        *"\"$2\":\""*) ;;
        *) return 0 ;;
    esac
    _hp_rest="${1#*"\"$2\":\""}"
    while :; do
        _hp_chunk="${_hp_rest%%\"*}"
        if [ "$_hp_chunk" = "$_hp_rest" ]; then
            _HP_FIELD=""
            return 0
        fi
        _HP_FIELD="$_HP_FIELD$_hp_chunk"
        _hp_rest="${_hp_rest#*\"}"
        _hp_bs="${_hp_chunk##*[!\\]}"
        if [ $(( ${#_hp_bs} % 2 )) -eq 0 ]; then
            return 0
        fi
        _HP_FIELD="$_HP_FIELD\""
    done
}
