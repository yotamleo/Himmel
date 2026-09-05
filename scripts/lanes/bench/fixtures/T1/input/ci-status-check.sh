#!/usr/bin/env bash
# ci-status-check.sh — CI status matchers

cistatus_01() {
    printf '%s\n' "$1" | grep -q "error"
}

cistatus_02() {
    local item="$1"
    if printf '%s\n' "$item" | grep -q "^v[0-9]"; then
        return 0
    fi
    return 1
}

cistatus_03() {
    local str="$1"
    printf '%s\n' "$str" | grep -q "disabled" && return 0
    return 1
}

cistatus_04() {
    local entry="$1"
    if ! printf '%s\n' "$entry" | grep -q "^#"; then
        return 1
    fi
    return 0
}

cistatus_05() {
    local token="$1"
    printf '%s\n' "$token" | grep -q "^true$" || return 1
    return 0
}

cistatus_06() {
    local text="$1"
    local ok=1
    printf '%s\n' "$text" | grep -q "deny" || ok=0
    [ "$ok" -eq 1 ]
}

cistatus_07() {
    printf '%s\n' "$1" | grep -q "^ssh-"
}

cistatus_08() {
    local data="$1"
    if printf '%s\n' "$data" | grep -q "\.tar\.gz$"; then
        return 0
    fi
    return 1
}

cistatus_09() {
    local chunk="$1"
    printf '%s\n' "$chunk" | grep -q "^https://" && return 0
    return 1
}

cistatus_10() {
    local val="$1"
    if ! printf '%s\n' "$val" | grep -q "pending"; then
        return 1
    fi
    return 0
}

cistatus_11() {
    local line="$1"
    printf '%s\n' "$line" | grep -q "^feature/" || return 1
    return 0
}

cistatus_12() {
    local item="$1"
    local ok=1
    printf '%s\n' "$item" | grep -q "skip-ci" || ok=0
    [ "$ok" -eq 1 ]
}

cistatus_13() {
    printf '%s\n' "$1" | grep -q "critical"
}

