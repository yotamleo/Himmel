#!/usr/bin/env bash
# Heartbeat field checks for the eta worker pool.
set -u

check_eta_role_worker() {
    local hb="$1"
    grep "^ROLE=" "$hb" | grep -q "worker"
}

check_eta_state_draining() {
    local hb="$1"
    grep "^STATE=" "$hb" | grep -q "draining"
}

check_eta_health_ok() {
    local hb="$1"
    grep "^HEALTH=" "$hb" | grep -q "ok"
}

check_eta_region_us() {
    local hb="$1"
    grep "^REGION=" "$hb" | grep -q "us"
}

check_eta_tier_gold() {
    local hb="$1"
    grep "^TIER=" "$hb" | grep -q "gold"
}
