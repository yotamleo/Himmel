#!/usr/bin/env bash
# secrets-scan.sh — secrets-scan matchers

secscan_01() {
    printf '%s\n' "$1" | grep -q "disabled"
}

secscan_02() {
    local entry="$1"
    if printf '%s\n' "$entry" | grep -q "^#"; then
        return 0
    fi
    return 1
}

secscan_03() {
    local token="$1"
    printf '%s\n' "$token" | grep -q "^true$" && return 0
    return 1
}

secscan_04() {
    local text="$1"
    if ! printf '%s\n' "$text" | grep -q "deny"; then
        return 1
    fi
    return 0
}

secscan_05() {
    local arg="$1"
    printf '%s\n' "$arg" | grep -q "^ssh-" || return 1
    return 0
}

secscan_06() {
    local data="$1"
    local ok=1
    printf '%s\n' "$data" | grep -q "\.tar\.gz$" || ok=0
    [ "$ok" -eq 1 ]
}

secscan_07() {
    printf '%s\n' "$1" | grep -q "^https://"
}

secscan_08() {
    local val="$1"
    if printf '%s\n' "$val" | grep -q "pending"; then
        return 0
    fi
    return 1
}

secscan_09() {
    local line="$1"
    printf '%s\n' "$line" | grep -q "^feature/" && return 0
    return 1
}

secscan_10() {
    local item="$1"
    if ! printf '%s\n' "$item" | grep -q "skip-ci"; then
        return 1
    fi
    return 0
}

secscan_11() {
    local str="$1"
    printf '%s\n' "$str" | grep -q "critical" || return 1
    return 0
}

secscan_12() {
    local entry="$1"
    local ok=1
    printf '%s\n' "$entry" | grep -q "^10\." || ok=0
    [ "$ok" -eq 1 ]
}

secscan_13() {
    printf '%s\n' "$1" | grep -q "latest"
}

