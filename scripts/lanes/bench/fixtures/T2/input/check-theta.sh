#!/usr/bin/env bash
# Heartbeat field checks for the theta worker pool.
set -u

check_theta_role_leader() {
    local hb="$1"
    grep "^ROLE=" "$hb" | grep -q "leader"
}

check_theta_state_idle() {
    local hb="$1"
    grep "^STATE=" "$hb" | grep -q "idle"
}

check_theta_health_degraded() {
    local hb="$1"
    grep "^HEALTH=" "$hb" | grep -q "degraded"
}

check_theta_region_eu() {
    local hb="$1"
    grep "^REGION=" "$hb" | grep -q "eu"
}

check_theta_tier_silver() {
    local hb="$1"
    grep "^TIER=" "$hb" | grep -q "silver"
}
