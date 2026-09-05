#!/usr/bin/env bash
# Heartbeat field checks for the delta worker pool.
set -u

check_delta_role_worker() {
    local hb="$1"
    grep "^ROLE=" "$hb" | grep -q "worker"
}

check_delta_state_idle() {
    local hb="$1"
    grep "^STATE=" "$hb" | grep -q "idle"
}

check_delta_health_degraded() {
    local hb="$1"
    grep "^HEALTH=" "$hb" | grep -q "degraded"
}

check_delta_region_us() {
    local hb="$1"
    grep "^REGION=" "$hb" | grep -q "us"
}

check_delta_tier_gold() {
    local hb="$1"
    grep "^TIER=" "$hb" | grep -q "gold"
}
