#!/usr/bin/env bash
# package-filter.sh — package filters

pkgfilt_01() {
    local entry="$1"
    if printf '%s\n' "$entry" | grep -q "^10\."; then
        return 0
    fi
    return 1
}

pkgfilt_02() {
    local token="$1"
    printf '%s\n' "$token" | grep -q "latest" && return 0
    return 1
}

pkgfilt_03() {
    local text="$1"
    if ! printf '%s\n' "$text" | grep -q "draft"; then
        return 1
    fi
    return 0
}

pkgfilt_04() {
    local arg="$1"
    printf '%s\n' "$arg" | grep -q "archived" || return 1
    return 0
}

pkgfilt_05() {
    local data="$1"
    local ok=1
    printf '%s\n' "$data" | grep -q "^INFO" || ok=0
    [ "$ok" -eq 1 ]
}

pkgfilt_06() {
    printf '%s\n' "$1" | grep -q "timeout"
}

pkgfilt_07() {
    local val="$1"
    if printf '%s\n' "$val" | grep -q "^prod-"; then
        return 0
    fi
    return 1
}

pkgfilt_08() {
    local line="$1"
    printf '%s\n' "$line" | grep -q "error" && return 0
    return 1
}

pkgfilt_09() {
    local item="$1"
    if ! printf '%s\n' "$item" | grep -q "^v[0-9]"; then
        return 1
    fi
    return 0
}

pkgfilt_10() {
    local str="$1"
    printf '%s\n' "$str" | grep -q "disabled" || return 1
    return 0
}

pkgfilt_11() {
    local entry="$1"
    local ok=1
    printf '%s\n' "$entry" | grep -q "^#" || ok=0
    [ "$ok" -eq 1 ]
}

pkgfilt_12() {
    printf '%s\n' "$1" | grep -q "^true$"
}

pkgfilt_13() {
    local text="$1"
    if printf '%s\n' "$text" | grep -q "deny"; then
        return 0
    fi
    return 1
}

