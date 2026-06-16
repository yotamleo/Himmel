#!/usr/bin/env python3
"""
Ubuntu VirtualBox VM provisioner.

Prerequisites:
  - VM created in VirtualBox with NAT port forwarding: host 2222 -> guest 22
  - .env has ubuntu_vm_user and ubuntu_vm_pass
  - pip install paramiko python-dotenv

Usage:
  python scripts/machine-setup/ubuntu-vm-setup.py [--vm-name ubuntu_new]
"""

import os
import subprocess
import sys
import time
import argparse

try:
    import paramiko
except ImportError:
    sys.exit("Missing: pip install paramiko")

try:
    from dotenv import load_dotenv
except ImportError:
    sys.exit("Missing: pip install python-dotenv")

load_dotenv()

HOST = "127.0.0.1"
PORT = 2222
USER = os.environ.get("ubuntu_vm_user") or sys.exit("ubuntu_vm_user not in .env")
PASS = os.environ.get("ubuntu_vm_pass") or sys.exit("ubuntu_vm_pass not in .env")
PUBKEY_PATH = os.path.expanduser("~/.ssh/id_ed25519.pub").replace("\\", "/")


def connect(use_key=False):
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    kwargs = dict(hostname=HOST, port=PORT, username=USER, timeout=10)
    if use_key:
        kwargs["key_filename"] = PUBKEY_PATH.replace(".pub", "")
    else:
        kwargs["password"] = PASS
    client.connect(**kwargs)
    return client


def run(client, cmd, sudo=False, timeout=300):
    if sudo:
        cmd = f"echo '{PASS}' | sudo -S bash -c {repr(cmd)}"
    print(f"  $ {cmd[:90]}")
    stdin, stdout, stderr = client.exec_command(cmd, get_pty=True, timeout=timeout)
    out = stdout.read().decode(errors="replace")
    rc = stdout.channel.recv_exit_status()
    if rc != 0:
        err = stderr.read().decode(errors="replace")
        print(f"    [exit {rc}] {err.strip()[-200:]}")
    return rc, out


def vboxmanage(*args):
    vbm = r"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
    result = subprocess.run([vbm, *args], capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--vm-name", default="ubuntu_new", help="VirtualBox VM name")
    args = parser.parse_args()
    vm = args.vm_name

    print(f"\n=== Ubuntu VM Setup: {vm} ({USER}@{HOST}:{PORT}) ===\n")

    # --- GUEST SETUP ---
    print("[1/8] Connecting (password auth)...")
    client = connect()

    print("[2/8] Installing Guest Additions...")
    run(client, "DEBIAN_FRONTEND=noninteractive apt-get install -y virtualbox-guest-utils virtualbox-guest-x11", sudo=True, timeout=300)

    print("[3/8] Masking sleep/suspend targets...")
    run(client, "systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target", sudo=True)

    print("[4/8] Disabling Wayland (force X11)...")
    run(client, "sed -i 's/#WaylandEnable=false/WaylandEnable=false/' /etc/gdm3/custom.conf", sudo=True)

    print("[5/8] Enabling GDM3 auto-login...")
    run(client, f"sed -i 's/#  AutomaticLoginEnable = true/AutomaticLoginEnable = true/' /etc/gdm3/custom.conf", sudo=True)
    run(client, f"sed -i 's/#  AutomaticLogin = user1/AutomaticLogin = {USER}/' /etc/gdm3/custom.conf", sudo=True)

    print("[6/8] Creating /usr/local/bin/vboxclient-all...")
    script = "#!/bin/bash\\n/usr/bin/VBoxClient --clipboard &\\n/usr/bin/VBoxClient --vmsvga-session &\\n"
    run(client, f"printf '{script}' > /tmp/vboxclient-all && cp /tmp/vboxclient-all /usr/local/bin/vboxclient-all && chmod +x /usr/local/bin/vboxclient-all", sudo=True)

    print("[7/8] Creating /etc/xdg/autostart/vboxclient.desktop...")
    entry = "[Desktop Entry]\\nType=Application\\nName=VBoxClient\\nExec=/usr/local/bin/vboxclient-all\\nNoDisplay=true\\nX-GNOME-Autostart-enabled=true\\n"
    run(client, f"printf '{entry}' > /tmp/vboxclient.desktop && cp /tmp/vboxclient.desktop /etc/xdg/autostart/vboxclient.desktop", sudo=True)

    print("[7b] Copying SSH public key...")
    if os.path.exists(PUBKEY_PATH):
        pubkey = open(PUBKEY_PATH).read().strip()
        run(client, f'mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo "{pubkey}" >> ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys')
    else:
        print("  WARNING: no SSH key found at", PUBKEY_PATH)
        print("  Run: ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''")

    print("  Rebooting guest...")
    run(client, "reboot", sudo=True)
    client.close()

    # --- HOST SETUP (requires VM off) ---
    print("[8/8] Waiting for guest to power off...")
    for _ in range(60):
        rc, out = vboxmanage("showvminfo", vm, "--machinereadable")
        if 'VMState="poweroff"' in out:
            break
        time.sleep(2)
    else:
        print("  WARNING: VM did not power off in time — set clipboard manually:")
        print(f'  VBoxManage modifyvm "{vm}" --clipboard-mode bidirectional')
        return

    print("  Setting persistent bidirectional clipboard...")
    rc, out = vboxmanage("modifyvm", vm, "--clipboard-mode", "bidirectional")
    if rc != 0:
        print("  WARNING:", out.strip())

    print("  Starting VM with GUI...")
    vboxmanage("startvm", vm, "--type", "gui")

    print(f"\n=== Done! VM booting. SSH available at {HOST}:{PORT} ===")
    print(f"  ssh -p {PORT} -i ~/.ssh/id_ed25519 {USER}@{HOST}")


if __name__ == "__main__":
    main()
