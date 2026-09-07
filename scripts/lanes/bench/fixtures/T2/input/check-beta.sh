#!/usr/bin/env bash
# Heartbeat field checks for the beta worker pool.
set -u

check_beta_role_leader() {
    local hb="$1"
    grep "^ROLE=" "$hb" | grep -q "leader"
}

check_beta_state_active() {
    local hb="$1"
    grep "^STATE=" "$hb" | grep -q "active"
}

check_beta_health_warn() {
    local hb="$1"
    grep "^HEALTH=" "$hb" | grep -q "warn"
}

check_beta_region_eu() {
    local hb="$1"
    grep "^REGION=" "$hb" | grep -q "eu"
}

check_beta_tier_silver() {
    local hb="$1"
    grep "^TIER=" "$hb" | grep -q "silver"
}
