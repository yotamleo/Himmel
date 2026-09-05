#!/usr/bin/env bash
# Heartbeat field checks for the gamma worker pool.
set -u

check_gamma_role_replica() {
    local hb="$1"
    grep "^ROLE=" "$hb" | grep -q "replica"
}

check_gamma_state_draining() {
    local hb="$1"
    grep "^STATE=" "$hb" | grep -q "draining"
}

check_gamma_health_ok() {
    local hb="$1"
    grep "^HEALTH=" "$hb" | grep -q "ok"
}

check_gamma_region_ap() {
    local hb="$1"
    grep "^REGION=" "$hb" | grep -q "ap"
}

check_gamma_tier_bronze() {
    local hb="$1"
    grep "^TIER=" "$hb" | grep -q "bronze"
}
