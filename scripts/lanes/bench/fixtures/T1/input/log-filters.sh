#!/usr/bin/env bash
# log-filters.sh — log line filters

logfilt_01() {
    local text="$1"
    if ! printf '%s\n' "$text" | grep -q "draft"; then
        return 1
    fi
    return 0
}

logfilt_02() {
    local arg="$1"
    printf '%s\n' "$arg" | grep -q "archived" || return 1
    return 0
}

logfilt_03() {
    local data="$1"
    local ok=1
    printf '%s\n' "$data" | grep -q "^INFO" || ok=0
    [ "$ok" -eq 1 ]
}

logfilt_04() {
    printf '%s\n' "$1" | grep -q "timeout"
}

logfilt_05() {
    local val="$1"
    if printf '%s\n' "$val" | grep -q "^prod-"; then
        return 0
    fi
    return 1
}

logfilt_06() {
    local line="$1"
    printf '%s\n' "$line" | grep -q "error" && return 0
    return 1
}

logfilt_07() {
    local item="$1"
    if ! printf '%s\n' "$item" | grep -q "^v[0-9]"; then
        return 1
    fi
    return 0
}

logfilt_08() {
    local str="$1"
    printf '%s\n' "$str" | grep -q "disabled" || return 1
    return 0
}

logfilt_09() {
    local entry="$1"
    local ok=1
    printf '%s\n' "$entry" | grep -q "^#" || ok=0
    [ "$ok" -eq 1 ]
}

logfilt_10() {
    printf '%s\n' "$1" | grep -q "^true$"
}

logfilt_11() {
    local text="$1"
    if printf '%s\n' "$text" | grep -q "deny"; then
        return 0
    fi
    return 1
}

logfilt_12() {
    local arg="$1"
    printf '%s\n' "$arg" | grep -q "^ssh-" && return 0
    return 1
}

logfilt_13() {
    local data="$1"
    if ! printf '%s\n' "$data" | grep -q "\.tar\.gz$"; then
        return 1
    fi
    return 0
}

logfilt_14() {
    local chunk="$1"
    printf '%s\n' "$chunk" | grep -q "^https://" || return 1
    return 0
}

