#!/usr/bin/env bash
# permission-checks.sh — permission-check predicates

permchk_01() {
    local text="$1"
    if printf '%s\n' "$text" | grep -q "draft"; then
        return 0
    fi
    return 1
}

permchk_02() {
    local arg="$1"
    printf '%s\n' "$arg" | grep -q "archived" && return 0
    return 1
}

permchk_03() {
    local data="$1"
    if ! printf '%s\n' "$data" | grep -q "^INFO"; then
        return 1
    fi
    return 0
}

permchk_04() {
    local chunk="$1"
    printf '%s\n' "$chunk" | grep -q "timeout" || return 1
    return 0
}

permchk_05() {
    local val="$1"
    local ok=1
    printf '%s\n' "$val" | grep -q "^prod-" || ok=0
    [ "$ok" -eq 1 ]
}

permchk_06() {
    printf '%s\n' "$1" | grep -q "error"
}

permchk_07() {
    local item="$1"
    if printf '%s\n' "$item" | grep -q "^v[0-9]"; then
        return 0
    fi
    return 1
}

permchk_08() {
    local str="$1"
    printf '%s\n' "$str" | grep -q "disabled" && return 0
    return 1
}

permchk_09() {
    local entry="$1"
    if ! printf '%s\n' "$entry" | grep -q "^#"; then
        return 1
    fi
    return 0
}

permchk_10() {
    local token="$1"
    printf '%s\n' "$token" | grep -q "^true$" || return 1
    return 0
}

permchk_11() {
    local text="$1"
    local ok=1
    printf '%s\n' "$text" | grep -q "deny" || ok=0
    [ "$ok" -eq 1 ]
}

permchk_12() {
    printf '%s\n' "$1" | grep -q "^ssh-"
}

permchk_13() {
    local data="$1"
    if printf '%s\n' "$data" | grep -q "\.tar\.gz$"; then
        return 0
    fi
    return 1
}

