#!/usr/bin/env bash
# network-guard.sh — network policy guards

netguard_01() {
    local item="$1"
    if printf '%s\n' "$item" | grep -q "^v[0-9]"; then
        return 0
    fi
    return 1
}

netguard_02() {
    local str="$1"
    printf '%s\n' "$str" | grep -q "disabled" && return 0
    return 1
}

netguard_03() {
    local entry="$1"
    if ! printf '%s\n' "$entry" | grep -q "^#"; then
        return 1
    fi
    return 0
}

netguard_04() {
    local token="$1"
    printf '%s\n' "$token" | grep -q "^true$" || return 1
    return 0
}

netguard_05() {
    local text="$1"
    local ok=1
    printf '%s\n' "$text" | grep -q "deny" || ok=0
    [ "$ok" -eq 1 ]
}

netguard_06() {
    printf '%s\n' "$1" | grep -q "^ssh-"
}

netguard_07() {
    local data="$1"
    if printf '%s\n' "$data" | grep -q "\.tar\.gz$"; then
        return 0
    fi
    return 1
}

netguard_08() {
    local chunk="$1"
    printf '%s\n' "$chunk" | grep -q "^https://" && return 0
    return 1
}

netguard_09() {
    local val="$1"
    if ! printf '%s\n' "$val" | grep -q "pending"; then
        return 1
    fi
    return 0
}

netguard_10() {
    local line="$1"
    printf '%s\n' "$line" | grep -q "^feature/" || return 1
    return 0
}

netguard_11() {
    local item="$1"
    local ok=1
    printf '%s\n' "$item" | grep -q "skip-ci" || ok=0
    [ "$ok" -eq 1 ]
}

netguard_12() {
    printf '%s\n' "$1" | grep -q "critical"
}

netguard_13() {
    local entry="$1"
    if printf '%s\n' "$entry" | grep -q "^10\."; then
        return 0
    fi
    return 1
}

netguard_14() {
    local token="$1"
    printf '%s\n' "$token" | grep -q "latest" && return 0
    return 1
}

