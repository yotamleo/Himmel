#!/usr/bin/env python3
"""
VirtualBox control helper (HIMMEL-491 seed for the cross-OS provisioning SDK).

Covers the two infra needs surfaced while bootstrapping the Windows test VM:
  - power on / off / ensure-running by VM name, so we never run both the Ubuntu
    and Windows VMs at once and OOM the host (concurrent VMs + a Windows Update
    servicing run wedged the host this session).
  - persist the NAT ssh forward via `modifyvm` (survives a full power-cycle),
    instead of the runtime `controlvm natpf1` rule which is lost on power-off.

Pure stdlib (subprocess) so it has no dependency beyond VBoxManage itself.

Used by scripts/machine-setup/windows-vm-setup.py and (later) the full SDK.
"""

import os
import socket
import subprocess
import time

# Standard install path on Windows; overridable for non-default installs / CI.
VBOXMANAGE = os.environ.get(
    "VBOXMANAGE_PATH", r"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
)


class VBoxError(RuntimeError):
    pass


def _run(*args, timeout=120):
    r = subprocess.run([VBOXMANAGE, *args], capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def _info(vm):
    rc, out = _run("showvminfo", vm, "--machinereadable")
    if rc != 0:
        raise VBoxError(f"showvminfo {vm} failed: {out.strip()[-200:]}")
    return out


def state(vm):
    """Return the VM's VMState (e.g. 'running', 'poweroff', 'saved')."""
    for line in _info(vm).splitlines():
        if line.startswith("VMState="):
            return line.split("=", 1)[1].strip().strip('"')
    return "unknown"


def is_running(vm):
    return state(vm) == "running"


def power_on(vm, gui=False):
    """Start the VM if it is not already running. Headless by default."""
    if is_running(vm):
        return
    rc, out = _run("startvm", vm, "--type", "gui" if gui else "headless")
    if rc != 0:
        raise VBoxError(f"startvm {vm} failed: {out.strip()[-200:]}")


def power_off(vm, graceful=True, wait=60):
    """Power the VM off. Tries ACPI shutdown first, falls back to a hard poweroff."""
    if state(vm) == "poweroff":
        return
    if graceful:
        _run("controlvm", vm, "acpipowerbutton")
        deadline = time.time() + wait
        while time.time() < deadline:
            if state(vm) == "poweroff":
                return
            time.sleep(2)
    rc, out = _run("controlvm", vm, "poweroff")
    if rc != 0 and state(vm) != "poweroff":
        raise VBoxError(f"poweroff {vm} failed: {out.strip()[-200:]}")


def ensure_running(vm, gui=False):
    """Idempotently bring the VM up; no-op if already running."""
    if not is_running(vm):
        power_on(vm, gui=gui)


def get_forwards(vm):
    """Return a list of (name, proto, hostip, hostport, guestip, guestport)."""
    out, forwards = _info(vm), []
    for line in out.splitlines():
        if line.startswith("Forwarding(") and "=" in line:
            spec = line.split("=", 1)[1].strip().strip('"')
            parts = spec.split(",")
            if len(parts) == 6:
                forwards.append(tuple(parts))
    return forwards


def ensure_persistent_forward(vm, name, host_port, guest_port, host_ip="127.0.0.1"):
    """Ensure a *persistent* NAT forward (survives power-cycle) via modifyvm.

    Requires the VM to be powered off (VirtualBox refuses modifyvm natpf on a
    running VM). Removes any same-named rule first so the binding is exact —
    this is how we pin the forward to loopback (host_ip 127.0.0.1) rather than
    the wide 0.0.0.0 a bare `controlvm` rule defaults to.
    """
    if state(vm) != "poweroff":
        raise VBoxError(
            f"ensure_persistent_forward needs {vm} powered off "
            f"(modifyvm natpf cannot run on a live VM)"
        )
    _run("modifyvm", vm, "--natpf1", "delete", name)  # ignore "rule not found"
    # spec form: name,proto,hostip,hostport,guestip,guestport (guestip empty)
    rule = f"{name},tcp,{host_ip},{host_port},,{guest_port}"
    rc, out = _run("modifyvm", vm, "--natpf1", rule)
    if rc != 0:
        raise VBoxError(f"modifyvm natpf1 add failed: {out.strip()[-200:]}")


def list_snapshots(vm):
    """Return snapshot names for the VM (empty list if none)."""
    rc, out = _run("snapshot", vm, "list", "--machinereadable")
    if rc != 0:
        return []  # "this machine does not have any snapshots"
    names = []
    for line in out.splitlines():
        if line.startswith("SnapshotName"):  # SnapshotName[="..."] / SnapshotName-1=...
            names.append(line.split("=", 1)[1].strip().strip('"'))
    return names


def take_snapshot(vm, name, description=""):
    """Take a snapshot (VM may be running or off)."""
    args = ["snapshot", vm, "take", name]
    if description:
        args += ["--description", description]
    rc, out = _run(*args, timeout=300)
    if rc != 0:
        raise VBoxError(f"snapshot take {name} failed: {out.strip()[-200:]}")


def restore_snapshot(vm, name):
    """Restore the VM to a snapshot. Requires the VM powered off."""
    if state(vm) != "poweroff":
        power_off(vm)
    rc, out = _run("snapshot", vm, "restore", name, timeout=300)
    if rc != 0:
        raise VBoxError(f"snapshot restore {name} failed: {out.strip()[-200:]}")


def ensure_clean_snapshot(vm, name):
    """Restore to `name` if it exists, else raise — caller must create the
    pristine baseline once (a bare PS+winget box) so cold-install tests reset to it.
    """
    if name not in list_snapshots(vm):
        raise VBoxError(
            f"snapshot {name!r} not found on {vm}; create the pristine baseline "
            f"once with take_snapshot({vm!r}, {name!r}) on a bare PS+winget box"
        )
    restore_snapshot(vm, name)


def wait_for_ssh(host, port, timeout=180, expect_banner="SSH-"):
    """Block until the SSH port answers with a banner, or raise on timeout."""
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=8) as s:
                banner = s.recv(64).decode(errors="replace")
                if expect_banner in banner:
                    return banner.strip()
                last = banner.strip()
        except OSError as e:
            last = str(e)
        time.sleep(3)
    raise VBoxError(f"ssh {host}:{port} not ready in {timeout}s (last: {last!r})")
