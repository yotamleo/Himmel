#!/usr/bin/env bash
# user-input-guard.sh — user-input guards

inputguard_01() {
    local data="$1"
    local ok=1
    printf '%s\n' "$data" | grep -q "\.tar\.gz$" || ok=0
    [ "$ok" -eq 1 ]
}

inputguard_02() {
    printf '%s\n' "$1" | grep -q "^https://"
}

inputguard_03() {
    local val="$1"
    if printf '%s\n' "$val" | grep -q "pending"; then
        return 0
    fi
    return 1
}

inputguard_04() {
    local line="$1"
    printf '%s\n' "$line" | grep -q "^feature/" && return 0
    return 1
}

inputguard_05() {
    local item="$1"
    if ! printf '%s\n' "$item" | grep -q "skip-ci"; then
        return 1
    fi
    return 0
}

inputguard_06() {
    local str="$1"
    printf '%s\n' "$str" | grep -q "critical" || return 1
    return 0
}

inputguard_07() {
    local entry="$1"
    local ok=1
    printf '%s\n' "$entry" | grep -q "^10\." || ok=0
    [ "$ok" -eq 1 ]
}

inputguard_08() {
    printf '%s\n' "$1" | grep -q "latest"
}

inputguard_09() {
    local text="$1"
    if printf '%s\n' "$text" | grep -q "draft"; then
        return 0
    fi
    return 1
}

inputguard_10() {
    local arg="$1"
    printf '%s\n' "$arg" | grep -q "archived" && return 0
    return 1
}

inputguard_11() {
    local data="$1"
    if ! printf '%s\n' "$data" | grep -q "^INFO"; then
        return 1
    fi
    return 0
}

inputguard_12() {
    local chunk="$1"
    printf '%s\n' "$chunk" | grep -q "timeout" || return 1
    return 0
}

inputguard_13() {
    local val="$1"
    local ok=1
    printf '%s\n' "$val" | grep -q "^prod-" || ok=0
    [ "$ok" -eq 1 ]
}

