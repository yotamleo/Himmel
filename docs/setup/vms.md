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
On Ubuntu the provisioner (`ubuntu-vm-setup.py`, step 7c) installs this
automatically: a *command-scoped* drop-in `/etc/sudoers.d/90-<user>-nopasswd`
(`apt-get`/`apt`/`dpkg`/`systemctl`/`tee` only — never a blanket `NOPASSWD:ALL`),
`visudo -cf`-validated before install and written `0440 root:root` (HIMMEL-492).
The host-driven validator `scripts/test-install-symmetry-vm.sh [user@host] [port]
[identity]` GAP-skips the git-dependent suites when git is absent rather than
failing, so it stays green on a not-yet-bootstrapped box.

The upgrade-path counterpart `scripts/test-luna-upgrade-vm.sh [user@host] [port]
[identity]` (HIMMEL-493 Linux, HIMMEL-522 Windows) stages the real
`templates/luna-second-brain/` to the VM and proves the `/luna-upgrade` ENGINE
(`scripts/upgrade.sh`): it runs the shipped hermetic engine suite + a real
scaffold→rollback→upgrade roundtrip (asserts owned files refresh, user content is
preserved byte-identical, the version stamp advances, and a re-run is
idempotent). Deterministic — no claude call. It is **cross-OS** and
auto-detects the guest via `echo %OS%` (`Windows_NT` on cmd.exe — the Windows
OpenSSH default shell — vs the literal `%OS%` on a POSIX guest):

- **Ubuntu** (`… 2222 …`): runs the suite + roundtrip under the guest shell.
- **Windows** (`<winuser>@localhost 2223 <key>`): runs the engine under Git Bash.
  Two distinct cmd.exe-dodges: (a) **staging** streams a plain `tar` over ssh
  stdin to avoid scp Windows-path translation and cmd quoting; (b) the **remote
  assertion body** is fed via stdin with its vars *prepended* (not a POSIX
  `VAR=x cmd` env-prefix, which cmd.exe — the default ssh shell — does not honor).
  It ALSO runs the PowerShell smoke `test-upgrade.ps1` to prove the PS entry
  (`upgrade.ps1` → Git Bash → `upgrade.sh`) wires through on real Windows. Needs
  the host pubkey in the guest's
  `%ProgramData%\ssh\administrators_authorized_keys` (the provisioner installs it).

The engine's real deps are a **working python + git + sha256sum** — NOT `node`
(it is never invoked; the prior node gate was vestigial). On Windows `python3` is
the Microsoft Store stub (on PATH but emits no stdout), so the engine and the
harness resolve a working interpreter by probing stdout, not `command -v`, and
fall back `python3 → python → py`. A bootstrap-floor Linux VM lacking python3
gets a best-effort `sudo apt-get install python3` (scoped NOPASSWD, HIMMEL-492).
Both VM e2e scripts exit 3 (not 1) when the VM is unreachable.

### Skill-pass VM e2e (HIMMEL-493)

`python scripts/test-luna-upgrade-skill-vm.py` (`--help` for options) is the
**dogfood path**: it drives the `/luna-upgrade` SKILL via an interactive
`claude` session on the `ubuntu_new` VM against a scaffolded old-version vault
and asserts the upgrade roundtrip on filesystem state. Where `test-luna-upgrade-vm.sh`
invokes `upgrade.sh` directly (deterministic, no claude call), this probe exercises
the full user-facing path — the same `/luna-upgrade` a real adopter hits. It
builds on the central VM control SDK (`scripts/lib/vmsdk.py`: `sync_repo` /
`install_plugin` / `drive_claude`).

Exit codes: `0` pass · `1` assertion failed · `3` environment (VM unreachable,
`claude` not installed / not authenticated, plugin-install env-block) — exit 3
is **not a defect**.

**NON-GATING**: a local on-demand probe only. It is NOT wired into pre-push /
pre-commit / PR CI — LLM-in-the-loop, VM-dependent, and billing-consuming means
it must never block a merge. Requires the `ubuntu_new` VM up with an authenticated
`claude`.

### Security-posture audit (HIMMEL-495)

`python scripts/lib/vm_posture.py <vm> [--json]` runs a fixed battery of
**read-only forensic checks** over the `vmsdk.VM` SSH layer and prints a
severity-grouped report (authorized_keys, listening sockets + NIC, auth.log
non-local logins, sudoers NOPASSWD, IP-forwarding). It replaces the throwaway
`$TEMP` paramiko *forensic* sweeps every e2e session used to re-write: it is
reusable, hermetically tested (no VM needed to run `test-vm_posture.py`), and
read-only (re-running changes nothing on the guest — it never powers the VM
on/off). Exit `0` = no FAIL; `1` = a real violation; `3` = VM unreachable (bring
it up first); `4` = non-ubuntu guest (v1 is Ubuntu-only). This audits *security
posture* only — the *functional* smoke ("is claude installed, is the vault
present" — the `vm-probe*.py` `$TEMP` scripts) is a separate, still-needed
concern and is NOT replaced by this tool.

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
| 7c | Install scoped NOPASSWD sudoers drop-in (`visudo`-validated, `0440 root`) | guest |
| 8 | Set bidirectional clipboard (requires VM off → on) | host |

---

## Power Management (no sleep)

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
systemctl status sleep.target   # verify: masked
```

---

## Windows VM

`win11_base_himmel` — NAT port forward host `2223` → guest `22` (Windows
OpenSSH). The default ssh shell is **cmd.exe**; the himmel runtime runs under
**Git Bash** (`C:\Program Files\Git`, both `cmd` and `bin` on PATH so `git` and
`bash` are directly callable). `node`, `python` (NOT `python3` — that name is the
Microsoft Store stub), `sha256sum`/`find`/`tar` (via Git Bash), and PowerShell 7
(`pwsh`) are present.

### Credentials
Read from `.env`: `windows_vm_user`, `windows_vm_pass`.

### SSH key auth
Members of Administrators authenticate via the SYSTEM-wide
`%ProgramData%\ssh\administrators_authorized_keys` (NOT `~/.ssh`), with an ACL
restricted to `SYSTEM` + `BUILTIN\Administrators`. The provisioner
(`windows-vm-setup.py`, `install_pubkey`) appends the host pubkey and resets the
ACL. If key auth is rejected, (re)install the pubkey there — password auth via
`scripts/lib/vmsdk.py` still works as the fallback.

### Provision / drive
`python scripts/machine-setup/windows-vm-setup.py` (bootstrap floor: Git Bash +
jq via winget). Drive over SSH with `scripts/lib/vmsdk.py` (`VM('win11_base_himmel')`,
password + key-fallback auth). Inline `bash -lc '…'` through cmd.exe mangles
pipes/quotes — feed bodies via stdin or `powershell -EncodedCommand`.

### Connect
```bash
ssh -p 2223 <windows_vm_user>@127.0.0.1
```

---

## Quick Reference

| VM | Port | User var | Pass var | Key |
|----|------|----------|----------|-----|
| Ubuntu | 2222 | `ubuntu_vm_user` | `ubuntu_vm_pass` | `~/.ssh/id_ed25519` |
| Windows (`win11_base_himmel`) | 2223 | `windows_vm_user` | `windows_vm_pass` | `~/.ssh/id_ed25519` → `administrators_authorized_keys` |
