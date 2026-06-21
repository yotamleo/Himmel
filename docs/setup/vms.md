# VirtualBox VMs

Local VMs for testing and automation. Credentials stored in `.env` — see `.env.example` for variable names.

To provision a fresh Ubuntu VM run: `python scripts/machine-setup/ubuntu-vm-setup.py`

## Dependency split — test-harness vs user-runtime (HIMMEL-469)

Two **different** dependency sets; do not conflate them:

| Set | Who needs it | Deps | Installed by |
|-----|--------------|------|--------------|
| **Test harness** | throwaway test VMs + CI runners (to *run* himmel's bash suites) | `bash git jq` | `scripts/machine-setup/test-bootstrap.sh` |
| **User runtime** | himmel adopters (to *use* himmel) | `bash git node npm bun python3 jq gh mktemp` (+ `claude`) | `scripts/setup.sh` `[0/10]` (R6 `ensure-tools` auto-installs git/jq/python3, flags the rest) |

A bare test VM only needs `test-bootstrap.sh` to run the suites — it does **not**
need the full user runtime. `bash scripts/machine-setup/test-bootstrap.sh`
(`--check` to report only, `--no-sudo` if already root).

**Provision test VMs / CI with NOPASSWD sudo** (or run as root) so `test-bootstrap`
and the R6 `ensure-tools` apt path run non-interactively — a password-prompted
`sudo` over a non-TTY ssh fails with `A terminal is required to authenticate`.
The host-driven validator `scripts/test-install-symmetry-vm.sh [user@host] [port]
[identity]` GAP-skips the git-dependent suites when git is absent rather than
failing, so it stays green on a not-yet-bootstrapped box.

---

## Ubuntu VM

### VirtualBox Configuration

| Setting | Value |
|---------|-------|
| Network | NAT |
| Port forwarding | Host `2222` → Guest `22` |
| Clipboard | Bidirectional (persistent via `modifyvm`) |
| Guest Additions | `virtualbox-guest-utils` + `virtualbox-guest-x11` v7.0.20 |
| Kernel | `6.14.0-37-generic` |
| Display session | X11 (Wayland disabled — required for clipboard + full-screen) |

### Credentials

Read from `.env`:
- `ubuntu_vm_user` — SSH username
- `ubuntu_vm_pass` — SSH password (also used for sudo)

### SSH Key

Generated at `~/.ssh/id_ed25519` (ED25519). Public key copied to VM's `~/.ssh/authorized_keys`.

### Connect

```bash
ssh -p 2222 osboxes@127.0.0.1
```

### Start / Show VM

```powershell
# Start from off
VBoxManage startvm "ubuntu_new" --type gui

# Attach GUI to already-running headless VM
& "C:\Program Files\Oracle\VirtualBox\VirtualBoxVM.exe" --startvm "ubuntu_new"
```

Full-screen: `Right Ctrl + F`

### Automate via Paramiko

```python
import paramiko, os
from dotenv import load_dotenv

load_dotenv()
client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

# Password auth
client.connect("127.0.0.1", port=2222,
               username=os.environ["ubuntu_vm_user"],
               password=os.environ["ubuntu_vm_pass"])

# Key auth (after setup — no password needed)
# client.connect("127.0.0.1", port=2222,
#                username=os.environ["ubuntu_vm_user"],
#                key_filename="C:/Users/<user>/.ssh/id_ed25519")
```

> Install: `pip install paramiko --user`
> Python key paths must use Windows format: `C:/Users/...` not `/c/Users/...`

---

## From-Scratch Setup

Run the setup script (handles everything automatically):

```bash
python scripts/machine-setup/ubuntu-vm-setup.py
```

**Prerequisites before running:**
1. Ubuntu VM created in VirtualBox
2. NAT port forwarding configured: host `2222` → guest `22`
3. VM booted and SSH accessible
4. `.env` has `ubuntu_vm_user` and `ubuntu_vm_pass` set

### What the script does

| Step | What | Where |
|------|------|-------|
| 1 | Install Guest Additions (`virtualbox-guest-utils`, `virtualbox-guest-x11`) | guest |
| 2 | Mask sleep/suspend/hibernate targets | guest |
| 3 | Disable Wayland, force X11 session | guest |
| 4 | Enable GDM3 auto-login | guest |
| 5 | Create `/usr/local/bin/vboxclient-all` wrapper | guest |
| 6 | Create `/etc/xdg/autostart/vboxclient.desktop` | guest |
| 7 | Copy SSH public key to `~/.ssh/authorized_keys` | guest |
| 8 | Set bidirectional clipboard (requires VM off → on) | host |

---

## Power Management (no sleep)

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
systemctl status sleep.target   # verify: masked
```

---

## Windows VM

> Planned. Will add when configured.

Expected `.env` variables: `windows_vm_user`, `windows_vm_pass`

---

## Quick Reference

| VM | Port | User var | Pass var | Key |
|----|------|----------|----------|-----|
| Ubuntu | 2222 | `ubuntu_vm_user` | `ubuntu_vm_pass` | `~/.ssh/id_ed25519` |
| Windows | TBD | `windows_vm_user` | `windows_vm_pass` | TBD |
