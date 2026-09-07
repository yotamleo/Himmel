#!/usr/bin/env bash
# Heartbeat field checks for the alpha worker pool.
set -u

check_alpha_role_worker() {
    local hb="$1"
    grep "^ROLE=" "$hb" | grep -q "worker"
}

check_alpha_state_ready() {
    local hb="$1"
    grep "^STATE=" "$hb" | grep -q "ready"
}

check_alpha_health_ok() {
    local hb="$1"
    grep "^HEALTH=" "$hb" | grep -q "ok"
}

check_alpha_region_us() {
    local hb="$1"
    grep "^REGION=" "$hb" | grep -q "us"
}

check_alpha_tier_gold() {
    local hb="$1"
    grep "^TIER=" "$hb" | grep -q "gold"
}
