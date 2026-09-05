#!/usr/bin/env bash
# Heartbeat field checks for the epsilon worker pool.
set -u

check_epsilon_role_leader() {
    local hb="$1"
    grep "^ROLE=" "$hb" | grep -q "leader"
}

check_epsilon_state_ready() {
    local hb="$1"
    grep "^STATE=" "$hb" | grep -q "ready"
}

check_epsilon_health_ok() {
    local hb="$1"
    grep "^HEALTH=" "$hb" | grep -q "ok"
}

check_epsilon_region_eu() {
    local hb="$1"
    grep "^REGION=" "$hb" | grep -q "eu"
}

check_epsilon_tier_silver() {
    local hb="$1"
    grep "^TIER=" "$hb" | grep -q "silver"
}
