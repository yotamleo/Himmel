#!/usr/bin/env bash
# test-vm-mode.sh — hermetic tests for scripts/lib/vm-mode.sh (HIMMEL-4583).
# Every case runs against a temp HOME; the live ~/.himmel/config.json is never read.
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/vm-mode.sh"
failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/test-vm-mode.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.himmel"
unset HIMMEL_VM_MODE_CONFIG

cfg() { printf '%s\n' "$1" > "$T/home/.himmel/config.json"; }
run() { HOME="$T/home" bash "$LIB" "$@" 2>&1; }
check() { # <name> <expected output> <expected rc> <args...>
    local name="$1" want="$2" want_rc="$3" out rc
    shift 3
    out="$(run "$@")"; rc=$?
    if [ "$out" = "$want" ] && [ "$rc" = "$want_rc" ]; then pass "$name"
    else fail "$name: got rc=$rc '$out', want rc=$want_rc '$want'"; fi
}

echo "== no config file -> local (today's behaviour)"
check "absent config: mode" "local" 0 mode
check "absent config: route" "local-vm localhost:2222" 0 route
check "absent config: target" "$(printf 'localhost\t2222\t%s' "$T/home/.ssh/id_ed25519")" 0 target

echo "== config without vm -> local"
cfg '{"version":1,"luna":{}}'
check "no vm key: route" "local-vm localhost:2222" 0 route

echo "== vm.mode=local"
cfg '{"vm":{"mode":"local"}}'
check "local: route" "local-vm localhost:2222" 0 route

echo "== vm.mode=remote with ssh, port, identity"
cfg '{"vm":{"mode":"remote","remote":{"ssh":"ops@vm.example","port":2201,"identity":"~/.ssh/vm_key"}}}'
check "remote: mode" "remote" 0 mode
check "remote: route" "remote-vm ops@vm.example:2201" 0 route
check "remote: target expands identity" "$(printf 'ops@vm.example\t2201\t%s' "$T/home/.ssh/vm_key")" 0 target

echo "== vm.mode=remote, port defaults to 22"
cfg '{"vm":{"mode":"remote","remote":{"ssh":"ops@vm.example"}}}'
check "remote default port" "remote-vm ops@vm.example:22" 0 route

echo "== vm.mode=none -> operator ack, never a VM"
cfg '{"vm":{"mode":"none"}}'
check "none: mode" "none" 0 mode
check "none: route rc1" "operator-ack+rollback-point" 1 route
check "none: target refused" "vm.mode=none" 1 target

echo "== fail closed: anything unreadable or invalid is none"
cfg '{"vm":{"mode":"remote"}}'
check "remote without ssh -> none" "operator-ack+rollback-point" 1 route
check "remote without ssh: note" "vm.mode=none (vm.mode=remote but vm.remote.ssh is not set)" 1 target
cfg '{"vm":{"mode":"remote","remote":{"ssh":"-oProxyCommand=x"}}}'
check "ssh option-shaped -> none" "operator-ack+rollback-point" 1 route
cfg '{"vm":{"mode":"remote","remote":{"ssh":"ops@h","port":"22; x"}}}'
check "non-numeric port -> none" "operator-ack+rollback-point" 1 route
cfg '{"vm":{"mode":"remote","remote":{"ssh":"ops@h","port":true}}}'
check "boolean port -> none" "operator-ack+rollback-point" 1 route
cfg '{"vm":{"mode":"cloud"}}'
check "unknown mode -> none" "none" 0 mode
cfg '{"vm":'
check "malformed json -> none" "operator-ack+rollback-point" 1 route
cfg '[]'
check "non-object config -> none" "none" 0 mode
cfg '{"vm":"none"}'
check "non-object vm -> none" "none" 0 mode
cfg '{"vm":{"mode":"remote","remote":{"ssh":"ops@h","identity":"~/my key -oProxyCommand=x"}}}'
check "identity with whitespace -> none" "operator-ack+rollback-point" 1 route

echo "== sourced: vm_mode_load sets the variables"
cfg '{"vm":{"mode":"remote","remote":{"ssh":"ops@h","port":2202}}}'
out="$(HOME="$T/home" bash -c '. "$1"; vm_mode_load; printf "%s|%s|%s" "$VM_MODE" "$VM_MODE_HOST" "$VM_MODE_PORT"' _ "$LIB")"
if [ "$out" = "remote|ops@h|2202" ]; then pass "sourced load"; else fail "sourced load: '$out'"; fi

echo "== HIMMEL_VM_MODE_CONFIG seam"
printf '{"vm":{"mode":"none"}}\n' > "$T/other.json"
out="$(HIMMEL_VM_MODE_CONFIG="$T/other.json" HOME="$T/home" bash "$LIB" mode)"
if [ "$out" = "none" ]; then pass "config seam"; else fail "config seam: '$out'"; fi

if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
