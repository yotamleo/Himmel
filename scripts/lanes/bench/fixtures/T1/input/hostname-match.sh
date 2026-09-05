#!/usr/bin/env bash
# hostname-match.sh — hostname matchers

hostmatch_01() {
    local arg="$1"
    printf '%s\n' "$arg" | grep -q "^ssh-" && return 0
    return 1
}

hostmatch_02() {
    local data="$1"
    if ! printf '%s\n' "$data" | grep -q "\.tar\.gz$"; then
        return 1
    fi
    return 0
}

hostmatch_03() {
    local chunk="$1"
    printf '%s\n' "$chunk" | grep -q "^https://" || return 1
    return 0
}

hostmatch_04() {
    local val="$1"
    local ok=1
    printf '%s\n' "$val" | grep -q "pending" || ok=0
    [ "$ok" -eq 1 ]
}

hostmatch_05() {
    printf '%s\n' "$1" | grep -q "^feature/"
}

hostmatch_06() {
    local item="$1"
    if printf '%s\n' "$item" | grep -q "skip-ci"; then
        return 0
    fi
    return 1
}

hostmatch_07() {
    local str="$1"
    printf '%s\n' "$str" | grep -q "critical" && return 0
    return 1
}

hostmatch_08() {
    local entry="$1"
    if ! printf '%s\n' "$entry" | grep -q "^10\."; then
        return 1
    fi
    return 0
}

hostmatch_09() {
    local token="$1"
    printf '%s\n' "$token" | grep -q "latest" || return 1
    return 0
}

hostmatch_10() {
    local text="$1"
    local ok=1
    printf '%s\n' "$text" | grep -q "draft" || ok=0
    [ "$ok" -eq 1 ]
}

hostmatch_11() {
    printf '%s\n' "$1" | grep -q "archived"
}

hostmatch_12() {
    local data="$1"
    if printf '%s\n' "$data" | grep -q "^INFO"; then
        return 0
    fi
    return 1
}

hostmatch_13() {
    local chunk="$1"
    printf '%s\n' "$chunk" | grep -q "timeout" && return 0
    return 1
}

