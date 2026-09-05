#!/usr/bin/env bash
# state-machine.sh — deploy state-machine predicates

statemach_01() {
    local val="$1"
    local ok=1
    printf '%s\n' "$val" | grep -q "pending" || ok=0
    [ "$ok" -eq 1 ]
}

statemach_02() {
    printf '%s\n' "$1" | grep -q "^feature/"
}

statemach_03() {
    local item="$1"
    if printf '%s\n' "$item" | grep -q "skip-ci"; then
        return 0
    fi
    return 1
}

statemach_04() {
    local str="$1"
    printf '%s\n' "$str" | grep -q "critical" && return 0
    return 1
}

statemach_05() {
    local entry="$1"
    if ! printf '%s\n' "$entry" | grep -q "^10\."; then
        return 1
    fi
    return 0
}

statemach_06() {
    local token="$1"
    printf '%s\n' "$token" | grep -q "latest" || return 1
    return 0
}

statemach_07() {
    local text="$1"
    local ok=1
    printf '%s\n' "$text" | grep -q "draft" || ok=0
    [ "$ok" -eq 1 ]
}

statemach_08() {
    printf '%s\n' "$1" | grep -q "archived"
}

statemach_09() {
    local data="$1"
    if printf '%s\n' "$data" | grep -q "^INFO"; then
        return 0
    fi
    return 1
}

statemach_10() {
    local chunk="$1"
    printf '%s\n' "$chunk" | grep -q "timeout" && return 0
    return 1
}

statemach_11() {
    local val="$1"
    if ! printf '%s\n' "$val" | grep -q "^prod-"; then
        return 1
    fi
    return 0
}

statemach_12() {
    local line="$1"
    printf '%s\n' "$line" | grep -q "error" || return 1
    return 0
}

statemach_13() {
    local item="$1"
    local ok=1
    printf '%s\n' "$item" | grep -q "^v[0-9]" || ok=0
    [ "$ok" -eq 1 ]
}

