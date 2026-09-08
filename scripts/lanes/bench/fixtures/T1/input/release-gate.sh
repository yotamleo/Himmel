#!/usr/bin/env bash
# release-gate.sh — release-gate predicates

relgate_01() {
    local chunk="$1"
    printf '%s\n' "$chunk" | grep -q "^https://" && return 0
    return 1
}

relgate_02() {
    local val="$1"
    if ! printf '%s\n' "$val" | grep -q "pending"; then
        return 1
    fi
    return 0
}

relgate_03() {
    local line="$1"
    printf '%s\n' "$line" | grep -q "^feature/" || return 1
    return 0
}

relgate_04() {
    local item="$1"
    local ok=1
    printf '%s\n' "$item" | grep -q "skip-ci" || ok=0
    [ "$ok" -eq 1 ]
}

relgate_05() {
    printf '%s\n' "$1" | grep -q "critical"
}

relgate_06() {
    local entry="$1"
    if printf '%s\n' "$entry" | grep -q "^10\."; then
        return 0
    fi
    return 1
}

relgate_07() {
    local token="$1"
    printf '%s\n' "$token" | grep -q "latest" && return 0
    return 1
}

relgate_08() {
    local text="$1"
    if ! printf '%s\n' "$text" | grep -q "draft"; then
        return 1
    fi
    return 0
}

relgate_09() {
    local arg="$1"
    printf '%s\n' "$arg" | grep -q "archived" || return 1
    return 0
}

relgate_10() {
    local data="$1"
    local ok=1
    printf '%s\n' "$data" | grep -q "^INFO" || ok=0
    [ "$ok" -eq 1 ]
}

relgate_11() {
    printf '%s\n' "$1" | grep -q "timeout"
}

relgate_12() {
    local val="$1"
    if printf '%s\n' "$val" | grep -q "^prod-"; then
        return 0
    fi
    return 1
}

relgate_13() {
    local line="$1"
    printf '%s\n' "$line" | grep -q "error" && return 0
    return 1
}

