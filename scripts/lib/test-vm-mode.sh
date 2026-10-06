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

check_mode_err() { # <name>: mode prints none on stdout and exits 2 on a resolver error
    local out rc
    out="$(HOME="$T/home" bash "$LIB" mode 2>/dev/null)"; rc=$?
    if [ "$out" = none ] && [ "$rc" = 2 ]; then pass "$1"; else fail "$1: got rc=$rc '$out', want rc=2 'none'"; fi
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

echo "== a resolver error is not a configured none (J1932 T1): rc 2, the only offer is 'fix the config'"
cfg '{"vm":{"mode":"NONE"}}'
check "error wrong case: route rc2" "fix-config: vm.mode='NONE' is not local|remote|none -- fix ~/.himmel/config.json (docs/setup/vm-mode.md)" 2 route
check_mode_err "error wrong case: mode rc2"
check "error wrong case: target rc2" "vm.mode config error (vm.mode='NONE' is not local|remote|none)" 2 target
for shape in '{"vm":{"mode":"cloud"}}' '{"vm":{"mode":"none "}}' '{"vm":{"mode":""}}' '{"vm":{"mode":null}}' '{"vm":' '[]' '{"vm":"none"}' '{"vm":{"mode":"remote"}}' '{"vm":{"mode":"remote","remote":{"ssh":"-oProxyCommand=x"}}}' '{"vm":{"mode":"remote","remote":{"ssh":"ops@h","port":true}}}'; do
    cfg "$shape"
    out="$(run route)"; rc=$?
    case "$out" in fix-config:*operator-ack*) shape_ok=0 ;; fix-config:*) shape_ok=1 ;; *) shape_ok=0 ;; esac
    if [ "$rc" = 2 ] && [ "$shape_ok" = 1 ]; then pass "error shape $shape: route rc2 fix-config"
    else fail "error shape $shape: route rc=$rc '$out'"; fi
    out="$(run mode)"; rc=$?
    if [ "$rc" = 2 ]; then pass "error shape $shape: mode rc2"; else fail "error shape $shape: mode rc=$rc '$out'"; fi
done
rm -f "$T/home/.himmel/config.json"; mkdir "$T/home/.himmel/config.json"
out="$(run route)"; rc=$?
if [ "$rc" = 2 ]; then pass "error: config is a directory -> route rc2"; else fail "directory: route rc=$rc '$out'"; fi
rmdir "$T/home/.himmel/config.json"
cfg '{"vm":{"mode":"none"}}'
check "configured none stays rc1, never rc2" "operator-ack+rollback-point" 1 route
out="$(HOME="$T/home" bash -c '. "$1"; vm_mode_load; printf "%s|%s" "$VM_MODE" "$VM_MODE_ERROR"' _ "$LIB" 2>&1)"
if [ "$out" = "none|" ]; then pass "configured none: VM_MODE_ERROR empty"; else fail "configured none: '$out'"; fi
cfg '{"vm":{"mode":"bogus"}}'
out="$(HOME="$T/home" bash -c '. "$1"; vm_mode_load; printf "%s|%s" "$VM_MODE" "$VM_MODE_ERROR"' _ "$LIB" 2>&1)"
if [ "$out" = "none|1" ]; then pass "error: VM_MODE stays none (held), VM_MODE_ERROR=1"; else fail "error flag: '$out'"; fi

echo "== vm_mode_e2e_guard: none rc1 (SKIP), error rc2 (CONFIG ERROR, J1932 T2)"
guard() { HOME="$T/home" bash -c '. "$1"; vm_mode_e2e_guard suite-x' _ "$LIB" 2>&1; }
cfg '{"vm":{"mode":"none"}}'
out="$(guard)"; rc=$?
if [ "$rc" = 1 ] && grep -qF 'SKIP: vm.mode=none' <<< "$out"; then pass "guard none: rc1 SKIP"; else fail "guard none: rc=$rc '$out'"; fi
cfg '{"vm":{"mode":"Local"}}'
out="$(guard)"; rc=$?
if [ "$rc" = 2 ] && grep -qF 'CONFIG ERROR' <<< "$out" && ! grep -qF 'SKIP' <<< "$out"; then pass "guard error: rc2 CONFIG ERROR, not a SKIP"; else fail "guard error: rc=$rc '$out'"; fi
cfg '{"vm":{"mode":"local"}}'
out="$(guard)"; rc=$?
if [ "$rc" = 0 ]; then pass "guard local: rc0"; else fail "guard local: rc=$rc '$out'"; fi

echo "== fail closed: anything unreadable or invalid is none, as an error (rc 2), never the ack route"
cfg '{"vm":{"mode":"remote"}}'
check "remote without ssh -> none" "fix-config: vm.mode=remote but vm.remote.ssh is not set -- fix ~/.himmel/config.json (docs/setup/vm-mode.md)" 2 route
check "remote without ssh: note" "vm.mode config error (vm.mode=remote but vm.remote.ssh is not set)" 2 target
cfg '{"vm":{"mode":"remote","remote":{"ssh":"-oProxyCommand=x"}}}'
check "ssh option-shaped -> none" "fix-config: vm.remote has an invalid ssh, port or identity -- fix ~/.himmel/config.json (docs/setup/vm-mode.md)" 2 route
cfg '{"vm":{"mode":"remote","remote":{"ssh":"ops@h","port":"22; x"}}}'
check "non-numeric port -> none" "fix-config: vm.remote has an invalid ssh, port or identity -- fix ~/.himmel/config.json (docs/setup/vm-mode.md)" 2 route
cfg '{"vm":{"mode":"remote","remote":{"ssh":"ops@h","port":true}}}'
check "boolean port -> none" "fix-config: vm.remote has an invalid ssh, port or identity -- fix ~/.himmel/config.json (docs/setup/vm-mode.md)" 2 route
cfg '{"vm":{"mode":"cloud"}}'
check_mode_err "unknown mode -> none"
cfg '{"vm":'
out="$(run route)"; rc=$?
case "$out" in "fix-config: cannot parse "*) ok=1 ;; *) ok=0 ;; esac
if [ "$rc" = 2 ] && [ "$ok" = 1 ]; then pass "malformed json -> none"; else fail "malformed json: rc=$rc '$out'"; fi
cfg '[]'
check_mode_err "non-object config -> none"
cfg '{"vm":"none"}'
check_mode_err "non-object vm -> none"
cfg '{"vm":{"mode":"remote","remote":{"ssh":"ops@h","identity":"~/my key -oProxyCommand=x"}}}'
check "identity with whitespace -> none" "fix-config: vm.remote has an invalid ssh, port or identity -- fix ~/.himmel/config.json (docs/setup/vm-mode.md)" 2 route
mkdir -p "$T/sp home/.himmel"
printf '%s\n' '{"vm":{"mode":"remote","remote":{"ssh":"ops@h","identity":"~/.ssh/k"}}}' > "$T/sp home/.himmel/config.json"
out="$(HOME="$T/sp home" bash "$LIB" route 2>&1)"; rc=$?
if [ "$rc" = 2 ] && [ "$out" = "fix-config: vm.remote has an invalid ssh, port or identity -- fix ~/.himmel/config.json (docs/setup/vm-mode.md)" ]; then pass "identity expanding to whitespace -> none"
else fail "identity expanding to whitespace: rc=$rc '$out'"; fi
printf '%s\n' '{"vm":{"mode":"remote","remote":{"ssh":"ops@h"}}}' > "$T/sp home/.himmel/config.json"
out="$(HOME="$T/sp home" bash "$LIB" route 2>&1)"; rc=$?
if [ "$rc" = 2 ] && [ "$out" = "fix-config: vm.remote has an invalid ssh, port or identity -- fix ~/.himmel/config.json (docs/setup/vm-mode.md)" ]; then pass "remote default identity under a spaced HOME -> none"
else fail "remote default identity under a spaced HOME: rc=$rc '$out'"; fi
rm -f "$T/home/.himmel/config.json"; mkdir "$T/home/.himmel/config.json"
check_mode_err "config path is a directory -> none"
rmdir "$T/home/.himmel/config.json"; ln -s "$T/missing.json" "$T/home/.himmel/config.json"
check_mode_err "config is a dangling symlink -> none"
rm -f "$T/home/.himmel/config.json"

echo "== sourced: vm_mode_load sets the variables"
cfg '{"vm":{"mode":"remote","remote":{"ssh":"ops@h","port":2202}}}'
out="$(HOME="$T/home" bash -c '. "$1"; vm_mode_load; printf "%s|%s|%s" "$VM_MODE" "$VM_MODE_HOST" "$VM_MODE_PORT"' _ "$LIB")"
if [ "$out" = "remote|ops@h|2202" ]; then pass "sourced load"; else fail "sourced load: '$out'"; fi

echo "== HIMMEL_VM_MODE_CONFIG seam"
printf '{"vm":{"mode":"none"}}\n' > "$T/other.json"
out="$(HIMMEL_VM_MODE_CONFIG="$T/other.json" HOME="$T/home" bash "$LIB" mode)"
if [ "$out" = "none" ]; then pass "config seam"; else fail "config seam: '$out'"; fi

if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
