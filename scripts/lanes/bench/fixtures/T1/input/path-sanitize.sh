#!/usr/bin/env bash
# path-sanitize.sh — path sanitizers

pathsan_01() {
    local token="$1"
    printf '%s\n' "$token" | grep -q "latest" || return 1
    return 0
}

pathsan_02() {
    local text="$1"
    local ok=1
    printf '%s\n' "$text" | grep -q "draft" || ok=0
    [ "$ok" -eq 1 ]
}

pathsan_03() {
    printf '%s\n' "$1" | grep -q "archived"
}

pathsan_04() {
    local data="$1"
    if printf '%s\n' "$data" | grep -q "^INFO"; then
        return 0
    fi
    return 1
}

pathsan_05() {
    local chunk="$1"
    printf '%s\n' "$chunk" | grep -q "timeout" && return 0
    return 1
}

pathsan_06() {
    local val="$1"
    if ! printf '%s\n' "$val" | grep -q "^prod-"; then
        return 1
    fi
    return 0
}

pathsan_07() {
    local line="$1"
    printf '%s\n' "$line" | grep -q "error" || return 1
    return 0
}

pathsan_08() {
    local item="$1"
    local ok=1
    printf '%s\n' "$item" | grep -q "^v[0-9]" || ok=0
    [ "$ok" -eq 1 ]
}

pathsan_09() {
    printf '%s\n' "$1" | grep -q "disabled"
}

pathsan_10() {
    local entry="$1"
    if printf '%s\n' "$entry" | grep -q "^#"; then
        return 0
    fi
    return 1
}

pathsan_11() {
    local token="$1"
    printf '%s\n' "$token" | grep -q "^true$" && return 0
    return 1
}

pathsan_12() {
    local text="$1"
    if ! printf '%s\n' "$text" | grep -q "deny"; then
        return 1
    fi
    return 0
}

pathsan_13() {
    local arg="$1"
    printf '%s\n' "$arg" | grep -q "^ssh-" || return 1
    return 0
}

