#!/usr/bin/env bash
# config-validate.sh — config label validation

cfgval_01() {
    local val="$1"
    if printf '%s\n' "$val" | grep -q "^prod-"; then
        return 0
    fi
    return 1
}

cfgval_02() {
    local line="$1"
    printf '%s\n' "$line" | grep -q "error" && return 0
    return 1
}

cfgval_03() {
    local item="$1"
    if ! printf '%s\n' "$item" | grep -q "^v[0-9]"; then
        return 1
    fi
    return 0
}

cfgval_04() {
    local str="$1"
    printf '%s\n' "$str" | grep -q "disabled" || return 1
    return 0
}

cfgval_05() {
    local entry="$1"
    local ok=1
    printf '%s\n' "$entry" | grep -q "^#" || ok=0
    [ "$ok" -eq 1 ]
}

cfgval_06() {
    printf '%s\n' "$1" | grep -q "^true$"
}

cfgval_07() {
    local text="$1"
    if printf '%s\n' "$text" | grep -q "deny"; then
        return 0
    fi
    return 1
}

cfgval_08() {
    local arg="$1"
    printf '%s\n' "$arg" | grep -q "^ssh-" && return 0
    return 1
}

cfgval_09() {
    local data="$1"
    if ! printf '%s\n' "$data" | grep -q "\.tar\.gz$"; then
        return 1
    fi
    return 0
}

cfgval_10() {
    local chunk="$1"
    printf '%s\n' "$chunk" | grep -q "^https://" || return 1
    return 0
}

cfgval_11() {
    local val="$1"
    local ok=1
    printf '%s\n' "$val" | grep -q "pending" || ok=0
    [ "$ok" -eq 1 ]
}

cfgval_12() {
    printf '%s\n' "$1" | grep -q "^feature/"
}

cfgval_13() {
    local item="$1"
    if printf '%s\n' "$item" | grep -q "skip-ci"; then
        return 0
    fi
    return 1
}

cfgval_14() {
    local str="$1"
    printf '%s\n' "$str" | grep -q "critical" && return 0
    return 1
}

