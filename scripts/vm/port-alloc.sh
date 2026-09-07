#!/usr/bin/env bash
# port-alloc.sh — loopback port allocator for the HIMMEL-2623 after-report VM
# clones (himmel-ar-1 .. himmel-ar-$HIMMEL_VM_AR_MAX).
#
# Platform guard (linux-only): shells out to `VBoxManage list`/`showvminfo`
# on the Linux station; NOT ported to native PowerShell. A Windows port
# needs a VBoxManage.exe equivalent for both calls, and no Windows VM lane
# exists to test it against.
#
# Sourced by scripts/vm/after-report.sh and unit-tested directly by
# scripts/vm/test-after-report.sh (source it, stub VBoxManage on PATH, call
# the functions). Pure stdlib bash + VBoxManage (read-only ops only: `list
# vms` and `showvminfo --machinereadable` — never a lifecycle op) so it has
# no python dependency.
#
# WHY skip-the-claimed-set instead of counting up from a hardcoded base
# (HIMMEL-2623): a fixed base collides with whatever else is already
# registered on this station — today the `himmel-parity-audit` clone holds
# 2224, right above `ubuntu_new` (2222) and `win11_base_himmel` (2223), and
# nothing stops a FUTURE audit clone from landing on tomorrow's hardcoded
# base too. Skipping every port any REGISTERED VM already forwards is the
# only allocation rule that stays correct as the audit/ops fleet grows
# without this file's edit.
set -uo pipefail

: "${HIMMEL_VM_AR_BASE_PORT:=2231}"

# vm_ar_claimed_ports — print, one per line, every host port a REGISTERED
# VBoxManage VM already NAT-forwards. Read-only (`list vms` + `showvminfo
# --machinereadable`). CR finding codex-5: an unreadable/broken REGISTRY
# (VBoxManage missing, or `list vms` itself failing) must NOT read the same
# as "confirmed zero VMs claim anything" — the caller's whole allocation
# scheme depends on this enumeration being trustworthy when it succeeds, so
# a failure to enumerate returns NONZERO (fail closed) rather than empty
# output, which would otherwise hand out a port that IS in use somewhere
# this call just couldn't see. CR finding codex-3: a per-VM `showvminfo`
# failure for one already-listed name fails closed too, for the same
# reason — an inaccessible-but-still-registered VM is not proof it claims
# no ports, just proof this call couldn't see them.
vm_ar_claimed_ports() {
    local vbm="${VBOXMANAGE_PATH:-VBoxManage}"
    if ! command -v "$vbm" >/dev/null 2>&1; then
        echo "vm_ar_claimed_ports: '$vbm' not found on PATH — cannot enumerate claimed ports" >&2
        return 1
    fi
    local list_out
    if ! list_out=$("$vbm" list vms 2>/dev/null); then
        echo "vm_ar_claimed_ports: '$vbm list vms' failed — cannot enumerate claimed ports" >&2
        return 1
    fi
    local line vm
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # line shape: "name" {uuid} — strip the leading quote, keep up to
        # the NEXT quote (a VM name itself cannot contain one, VBoxManage
        # refuses it at creation).
        vm="${line#\"}"
        vm="${vm%%\"*}"
        [ -n "$vm" ] || continue
        # CR finding codex-3: `showvminfo` was piped straight into
        # grep/sed/awk, so its own exit status was invisible — the pipeline's
        # status was awk's, which is 0 regardless. A registered-but-currently
        # -inaccessible VM (e.g. mid-teardown, or the host lost track of its
        # backing disk) then silently contributed NO claimed ports, making
        # its port look free and risking a duplicate NAT allocation — the
        # same "can't see it so treat it as safe" failure this function's own
        # header calls out for the top-level `list vms` case. Capture first
        # so the real exit status is visible, and fail closed the same way.
        local vm_info
        if ! vm_info=$("$vbm" showvminfo "$vm" --machinereadable 2>/dev/null); then
            echo "vm_ar_claimed_ports: '$vbm showvminfo $vm' failed — cannot enumerate its claimed ports" >&2
            return 1
        fi
        grep -E '^Forwarding\([0-9]+\)=' <<< "$vm_info" \
            | sed -E 's/^Forwarding\([0-9]+\)="?//; s/"$//' \
            | awk -F',' '{ if (NF >= 4) print $4 }'
    done <<<"$list_out"
    return 0
}

# vm_ar_next_ports <count> — print <count> free loopback ports, one per
# line, starting at HIMMEL_VM_AR_BASE_PORT and stepping up, skipping any
# port already claimed by a registered VM (vm_ar_claimed_ports) AND any
# port already handed out earlier in this same call (so a multi-port
# request never returns duplicates).
vm_ar_next_ports() {
    local count="${1:?vm_ar_next_ports: count required}"
    case "$count" in ''|*[!0-9]*) echo "vm_ar_next_ports: count must be a non-negative integer, got '$count'" >&2; return 2 ;; esac
    local claimed
    if ! claimed=$(vm_ar_claimed_ports); then
        echo "vm_ar_next_ports: could not enumerate claimed ports — refusing to allocate (fail closed, CR finding codex-5)" >&2
        return 1
    fi
    local port=$HIMMEL_VM_AR_BASE_PORT found=0
    while [ "$found" -lt "$count" ]; do
        # here-string, not a pipe (HIMMEL-1430): under pipefail, `grep -q`
        # exits on its first match while $claimed may still be arriving,
        # SIGPIPEing the producer and inverting this negated guard on a
        # successful match. $claimed is small and already fully materialized
        # in-memory, so a here-string (written whole, no live producer to
        # race) removes the class outright rather than relying on size luck.
        if ! grep -qx "$port" <<< "$claimed"; then
            printf '%s\n' "$port"
            claimed="${claimed}
${port}"
            found=$((found + 1))
        fi
        port=$((port + 1))
    done
}

# vm_ar_vm_exists <name> — true (rc 0) iff VBoxManage already has a
# registered VM called <name> (exact match on the quoted name field of
# `list vms`).
vm_ar_vm_exists() {
    local name="${1:?vm_ar_vm_exists: name required}"
    local vbm="${VBOXMANAGE_PATH:-VBoxManage}"
    command -v "$vbm" >/dev/null 2>&1 || return 1
    # Capture, don't pipe into `grep -q` (HIMMEL-1430): `list vms` is an
    # EXTERNAL binary, and `grep -qF` can exit on the first match while it is
    # still writing a long registry, SIGPIPEing it and inverting this check
    # under pipefail on a genuine match. Capturing the full match set first
    # (grep without -q, so it drains its input rather than exiting early)
    # and testing non-emptiness afterward removes the race outright.
    local out
    out=$("$vbm" list vms 2>/dev/null | grep -F "\"$name\"")
    [ -n "$out" ]
}
