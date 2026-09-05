#!/usr/bin/env bash
# Heartbeat field checks for the zeta worker pool.
set -u

check_zeta_role_replica() {
    local hb="$1"
    grep "^ROLE=" "$hb" | grep -q "replica"
}

check_zeta_state_active() {
    local hb="$1"
    grep "^STATE=" "$hb" | grep -q "active"
}

check_zeta_health_warn() {
    local hb="$1"
    grep "^HEALTH=" "$hb" | grep -q "warn"
}

check_zeta_region_ap() {
    local hb="$1"
    grep "^REGION=" "$hb" | grep -q "ap"
}

check_zeta_tier_bronze() {
    local hb="$1"
    grep "^TIER=" "$hb" | grep -q "bronze"
}
