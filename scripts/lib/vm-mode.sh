#!/usr/bin/env bash
# vm-mode.sh — the one resolver for "VM proof first" (HIMMEL-4583).
#
# Several holds and rules say a step needs VM proof before it reaches the
# station. Whether that proof is possible, and by what route, is the adopter's
# setting, not a hardcoded local VM:
#
#   ~/.himmel/config.json
#   { "vm": { "mode": "local" | "remote" | "none",
#             "remote": { "ssh": "user@host", "port": 22,
#                         "identity": "~/.ssh/id_ed25519" } } }
#
#   local  (the default when vm.mode is unset or the file is absent) — today's
#          behaviour: the local test VM, ssh localhost:2222.
#   remote — vm.remote.ssh (+ port, default 22; identity, default
#          ~/.ssh/id_ed25519) names the VM to prove on.
#   none   — no VM proof is possible. A VM-proof hold is then satisfied only by
#          an operator ack plus a rollback point (a filesystem snapshot or a
#          backup of the touched paths, taken before the step, restore command
#          printed). It is never auto-released.
#
# Fail closed: a config that exists but cannot be read (malformed JSON, no
# python3), an unknown vm.mode value, or remote without vm.remote.ssh resolves
# to `none` with a note saying why — a hold is never released on a guess.
#
# Source it and call:
#   vm_mode_load        sets VM_MODE, VM_MODE_HOST, VM_MODE_PORT, VM_MODE_IDENT,
#                       VM_MODE_NOTE (why a value was not the one configured).
#   vm_mode             prints the mode.
#   vm_proof_route      prints the route a VM-proof hold resolves to:
#                         local-vm <host>:<port> | remote-vm <host>:<port> |
#                         operator-ack+rollback-point
#                       rc 0 = a VM can prove it; rc 1 = it cannot (none), so
#                       the hold stays HELD until the operator acks.
# Or run it: bash scripts/lib/vm-mode.sh mode|route|target
#
# Seam: HIMMEL_VM_MODE_CONFIG overrides the config path (tests use a temp HOME
# or this; nothing here ever writes the config). Bash 3.2-safe.

vm_mode_load() {
    local cfg="${HIMMEL_VM_MODE_CONFIG:-${HOME:-}/.himmel/config.json}" line
    VM_MODE=local VM_MODE_HOST=localhost VM_MODE_PORT=2222
    VM_MODE_IDENT="${HOME:-}/.ssh/id_ed25519" VM_MODE_NOTE=""
    [ -f "$cfg" ] || return 0
    if ! command -v python3 >/dev/null 2>&1; then
        VM_MODE=none VM_MODE_NOTE="python3 not found, cannot read $cfg"
        return 0
    fi
    local out
    out="$(python3 -c '
import json, os, sys
try:
    j = json.load(open(sys.argv[1]))
except Exception as e:
    print("mode=none"); print("note=cannot parse " + sys.argv[1]); sys.exit(0)
v = j.get("vm") if isinstance(j, dict) else None
v = v if isinstance(v, dict) else {}
m = v.get("mode", "local")
if m not in ("local", "remote", "none"):
    print("mode=none"); print("note=vm.mode=%r is not local|remote|none" % (m,)); sys.exit(0)
print("mode=" + m)
if m == "remote":
    r = v.get("remote") if isinstance(v.get("remote"), dict) else {}
    ssh = r.get("ssh")
    if not isinstance(ssh, str) or not ssh.strip():
        print("mode=none"); print("note=vm.mode=remote but vm.remote.ssh is not set"); sys.exit(0)
    ssh = ssh.strip()
    port = r.get("port", 22)
    ident = r.get("identity")
    bad = (ssh.startswith("-") or any(c.isspace() for c in ssh)
           or isinstance(port, bool) or not str(port).isdigit() or not 0 < int(port) < 65536
           or (ident is not None and (not isinstance(ident, str) or any(c in ident for c in "\r\n"))))
    if bad:
        print("mode=none"); print("note=vm.remote has an invalid ssh, port or identity"); sys.exit(0)
    print("host=" + ssh)
    print("port=%d" % int(port))
    if ident:
        print("ident=" + os.path.expanduser(ident))
' "$cfg" 2>/dev/null)" || { VM_MODE=none VM_MODE_NOTE="cannot read $cfg"; return 0; }
    while IFS= read -r line; do
        case "$line" in
            mode=*)  VM_MODE="${line#mode=}" ;;
            host=*)  VM_MODE_HOST="${line#host=}" ;;
            port=*)  VM_MODE_PORT="${line#port=}" ;;
            ident=*) VM_MODE_IDENT="${line#ident=}" ;;
            note=*)  VM_MODE_NOTE="${line#note=}" ;;
        esac
    done <<EOF
$out
EOF
    return 0
}

vm_mode() { vm_mode_load; printf '%s\n' "$VM_MODE"; }

vm_proof_route() {
    vm_mode_load
    case "$VM_MODE" in
        local)  printf 'local-vm %s:%s\n' "$VM_MODE_HOST" "$VM_MODE_PORT" ;;
        remote) printf 'remote-vm %s:%s\n' "$VM_MODE_HOST" "$VM_MODE_PORT" ;;
        *)      printf 'operator-ack+rollback-point\n'; return 1 ;;
    esac
}

# vm_mode_e2e_guard <suite> — for a host-driven VM e2e driver: under none,
# prints the SKIP reason and returns 1 (the driver exits 3, its "environment,
# not a code defect" code); otherwise loads the target into VM_MODE_HOST/PORT/IDENT.
vm_mode_e2e_guard() {
    vm_mode_load
    [ "$VM_MODE" != none ] && return 0
    echo "SKIP: vm.mode=none${VM_MODE_NOTE:+ ($VM_MODE_NOTE)} -- no VM to run $1 on; set vm.mode in ~/.himmel/config.json (docs/setup/vm-mode.md)" >&2
    return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        mode)  vm_mode ;;
        route) vm_proof_route ;;
        target)
            vm_mode_load
            [ "$VM_MODE" = none ] && { echo "vm.mode=none${VM_MODE_NOTE:+ ($VM_MODE_NOTE)}" >&2; exit 1; }
            printf '%s\t%s\t%s\n' "$VM_MODE_HOST" "$VM_MODE_PORT" "$VM_MODE_IDENT" ;;
        *) echo "usage: vm-mode.sh mode|route|target" >&2; exit 2 ;;
    esac
fi
