#!/usr/bin/env bash
# feature-flags.sh — feature-flag matchers

ffchk_01() {
    local item="$1"
    if ! printf '%s\n' "$item" | grep -q "^v[0-9]"; then
        return 1
    fi
    return 0
}

ffchk_02() {
    local str="$1"
    printf '%s\n' "$str" | grep -q "disabled" || return 1
    return 0
}

ffchk_03() {
    local entry="$1"
    local ok=1
    printf '%s\n' "$entry" | grep -q "^#" || ok=0
    [ "$ok" -eq 1 ]
}

ffchk_04() {
    printf '%s\n' "$1" | grep -q "^true$"
}

ffchk_05() {
    local text="$1"
    if printf '%s\n' "$text" | grep -q "deny"; then
        return 0
    fi
    return 1
}

ffchk_06() {
    local arg="$1"
    printf '%s\n' "$arg" | grep -q "^ssh-" && return 0
    return 1
}

ffchk_07() {
    local data="$1"
    if ! printf '%s\n' "$data" | grep -q "\.tar\.gz$"; then
        return 1
    fi
    return 0
}

ffchk_08() {
    local chunk="$1"
    printf '%s\n' "$chunk" | grep -q "^https://" || return 1
    return 0
}

ffchk_09() {
    local val="$1"
    local ok=1
    printf '%s\n' "$val" | grep -q "pending" || ok=0
    [ "$ok" -eq 1 ]
}

ffchk_10() {
    printf '%s\n' "$1" | grep -q "^feature/"
}

ffchk_11() {
    local item="$1"
    if printf '%s\n' "$item" | grep -q "skip-ci"; then
        return 0
    fi
    return 1
}

ffchk_12() {
    local str="$1"
    printf '%s\n' "$str" | grep -q "critical" && return 0
    return 1
}

ffchk_13() {
    local entry="$1"
    if ! printf '%s\n' "$entry" | grep -q "^10\."; then
        return 1
    fi
    return 0
}

