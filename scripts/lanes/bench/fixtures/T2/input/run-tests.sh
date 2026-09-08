#!/usr/bin/env bash
# run-tests.sh — behavioral checks for the check-*.sh heartbeat-field probes.
# Run from this directory: bash run-tests.sh
set -u

fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $desc (expected=$expected actual=$actual)" >&2
        fail=1
    fi
}

# run_check <file> <function> <field> <value>
run_check() {
    local file="$1" func="$2" field="$3" value="$4"
    . "./$file"

    local match_hb="$tmp/match.hb"
    local nomatch_hb="$tmp/nomatch.hb"
    local missing_hb="$tmp/missing.hb"

    printf '%s=%s-x1\n' "$field" "$value" > "$match_hb"
    printf '%s=zzz-none\n' "$field" > "$nomatch_hb"
    printf 'OTHER=zzz-none\n' > "$missing_hb"

    "$func" "$match_hb"
    assert_eq "$func matches" "0" "$?"

    "$func" "$nomatch_hb"
    assert_eq "$func rejects wrong value" "1" "$?"

    "$func" "$missing_hb"
    assert_eq "$func rejects missing field" "1" "$?"
}

TESTS='
check-alpha.sh check_alpha_role_worker ROLE worker
check-alpha.sh check_alpha_state_ready STATE ready
check-alpha.sh check_alpha_health_ok HEALTH ok
check-alpha.sh check_alpha_region_us REGION us
check-alpha.sh check_alpha_tier_gold TIER gold
check-beta.sh check_beta_role_leader ROLE leader
check-beta.sh check_beta_state_active STATE active
check-beta.sh check_beta_health_warn HEALTH warn
check-beta.sh check_beta_region_eu REGION eu
check-beta.sh check_beta_tier_silver TIER silver
check-gamma.sh check_gamma_role_replica ROLE replica
check-gamma.sh check_gamma_state_draining STATE draining
check-gamma.sh check_gamma_health_ok HEALTH ok
check-gamma.sh check_gamma_region_ap REGION ap
check-gamma.sh check_gamma_tier_bronze TIER bronze
check-delta.sh check_delta_role_worker ROLE worker
check-delta.sh check_delta_state_idle STATE idle
check-delta.sh check_delta_health_degraded HEALTH degraded
check-delta.sh check_delta_region_us REGION us
check-delta.sh check_delta_tier_gold TIER gold
check-epsilon.sh check_epsilon_role_leader ROLE leader
check-epsilon.sh check_epsilon_state_ready STATE ready
check-epsilon.sh check_epsilon_health_ok HEALTH ok
check-epsilon.sh check_epsilon_region_eu REGION eu
check-epsilon.sh check_epsilon_tier_silver TIER silver
check-zeta.sh check_zeta_role_replica ROLE replica
check-zeta.sh check_zeta_state_active STATE active
check-zeta.sh check_zeta_health_warn HEALTH warn
check-zeta.sh check_zeta_region_ap REGION ap
check-zeta.sh check_zeta_tier_bronze TIER bronze
check-eta.sh check_eta_role_worker ROLE worker
check-eta.sh check_eta_state_draining STATE draining
check-eta.sh check_eta_health_ok HEALTH ok
check-eta.sh check_eta_region_us REGION us
check-eta.sh check_eta_tier_gold TIER gold
check-theta.sh check_theta_role_leader ROLE leader
check-theta.sh check_theta_state_idle STATE idle
check-theta.sh check_theta_health_degraded HEALTH degraded
check-theta.sh check_theta_region_eu REGION eu
check-theta.sh check_theta_tier_silver TIER silver
'

while read -r file func field value; do
    [ -n "$file" ] || continue
    run_check "$file" "$func" "$field" "$value"
done <<EOF
$TESTS
EOF

if [ "$fail" -eq 0 ]; then
    echo "OK: all checks passed"
    exit 0
else
    echo "FAIL: one or more checks failed"
    exit 1
fi
