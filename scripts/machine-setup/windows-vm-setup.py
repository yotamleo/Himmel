#!/usr/bin/env python3
"""
Windows VirtualBox VM provisioner (HIMMEL-490) — the parallel to
ubuntu-vm-setup.py, but it installs ONLY the bootstrap floor, deliberately NOT
the himmel user runtime.

Why the split (see docs/setup/vms.md): the whole point of the clean-VM e2e is to
TEST himmel's own setup.sh. If this provisioner pre-installed node/bun/etc, then
setup.sh would have nothing to do and we would never actually test the install
path. So this script brings only what a bash-based setup.sh CANNOT bootstrap for
itself on a fresh Windows box:

  Layer 1 — bootstrap floor (this script):  OpenSSH (already enabled) + Git for
            Windows (provides `git` AND the Git Bash interpreter every himmel
            bash script needs).
  Layer 2 — test-harness (this script, +jq): jq, to run the bash suites.
  Layer 3 — user runtime (NOT here — himmel setup.sh / ensure-tools, UNDER TEST):
            node, npm, bun, python3, gh-config, claude, plugins, hooks.

If setup.sh can't auto-install a layer-3 tool on Windows, that is a real finding
the e2e should surface — not something this script masks.

Prerequisites:
  - VM has OpenSSH Server running and a NAT forward to host:2223 (set up once;
    see docs/setup/vms.md). `python -m pip install paramiko python-dotenv`.
  - .env has windows_vm_user and windows_vm_pass.

Usage:
  python scripts/machine-setup/windows-vm-setup.py [--vm-name win11_base_himmel]
                                                   [--port 2223] [--check]
"""

import argparse
import os
import sys

try:
    import paramiko
except ImportError:
    sys.exit("Missing: python -m pip install paramiko")
try:
    from dotenv import load_dotenv
except ImportError:
    sys.exit("Missing: python -m pip install python-dotenv")

load_dotenv()

HOST = "127.0.0.1"
USER = os.environ.get("windows_vm_user") or sys.exit("windows_vm_user not in .env")
PASS = os.environ.get("windows_vm_pass") or sys.exit("windows_vm_pass not in .env")
PUBKEY_PATH = os.path.expanduser("~/.ssh/id_ed25519.pub").replace("\\", "/")

# Layer-1/2 floor only. winget IDs. NOT node/bun — those are setup.sh's job.
FLOOR_PACKAGES = [
    ("Git.Git", "git"),       # brings git + the Git Bash interpreter
    ("jqlang.jq", "jq"),      # test-harness dep to run the bash suites
]


def connect(use_key=False, port=2223):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    kw = dict(hostname=HOST, port=port, username=USER, timeout=15,
              allow_agent=False, look_for_keys=False)
    if use_key:
        kw["key_filename"] = PUBKEY_PATH.replace(".pub", "")
    else:
        kw["password"] = PASS
    c.connect(**kw)
    return c


def run(client, cmd, timeout=600):
    """Run a command in the guest's default shell (cmd.exe) and return (rc, out)."""
    stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode(errors="replace")
    err = stderr.read().decode(errors="replace")
    rc = stdout.channel.recv_exit_status()
    return rc, (out + err)


def have(client, exe):
    """True if `exe` resolves on the guest PATH (via `where`)."""
    rc, _ = run(client, f"where {exe}", timeout=30)
    return rc == 0


def install_pubkey(client):
    """Append the host pubkey to the guest's administrators_authorized_keys.

    On Windows OpenSSH, members of Administrators use the SYSTEM-wide
    %ProgramData%\\ssh\\administrators_authorized_keys (NOT ~/.ssh), and its ACL
    must allow only SYSTEM + Administrators. We append idempotently and reset ACL.
    """
    if not os.path.exists(PUBKEY_PATH):
        print(f"  WARNING: no SSH key at {PUBKEY_PATH} — skipping key auth setup")
        print("  Run: ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''")
        return False
    with open(PUBKEY_PATH) as f:
        pub = f.read().strip()
    ps = (
        "powershell -NoProfile -Command "
        f"\"$k='{pub}'; $f=\\\"$env:ProgramData\\ssh\\administrators_authorized_keys\\\"; "
        "if(-not(Test-Path $f) -or -not(Select-String -SimpleMatch $k $f -EA SilentlyContinue))"
        "{Add-Content -Path $f -Value $k};"
        "icacls $f /inheritance:r /grant 'SYSTEM:F' 'BUILTIN\\Administrators:F' | Out-Null\""
    )
    rc, out = run(client, ps, timeout=60)
    if rc != 0:
        print(f"  WARNING: pubkey install rc={rc}: {out.strip()[-200:]}")
        return False
    return True


def winget_install(client, pkg_id):
    cmd = (
        f"winget install --id {pkg_id} --exact --silent "
        "--accept-source-agreements --accept-package-agreements "
        "--disable-interactivity"
    )
    return run(client, cmd, timeout=900)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vm-name", default="win11_base_himmel")
    ap.add_argument("--port", type=int, default=2223)
    ap.add_argument("--check", action="store_true", help="report floor state, install nothing")
    args = ap.parse_args()

    print(f"\n=== Windows VM provision (floor only): {args.vm_name} "
          f"({USER}@{HOST}:{args.port}) ===\n")

    print("[1/4] Connecting (password auth)...")
    client = connect(use_key=False, port=args.port)
    rc, who = run(client, "whoami", timeout=30)
    print(f"  connected as {who.strip()}")

    print("[2/4] Floor inventory...")
    state = {exe: have(client, exe) for _, exe in FLOOR_PACKAGES}
    for _, exe in FLOOR_PACKAGES:
        print(f"  {exe:8} {'present' if state[exe] else 'MISSING'}")
    # Git Bash interpreter specifically (distinct from git.exe being on PATH)
    rc, gb = run(client, r'if exist "C:\Program Files\Git\bin\bash.exe" (echo yes) else (echo no)', timeout=30)
    bash_present = "yes" in gb.lower()
    print(f"  {'bash':8} {'present (Git Bash)' if bash_present else 'MISSING'}")

    if args.check:
        missing = [e for _, e in FLOOR_PACKAGES if not state[e]] + ([] if bash_present else ["bash"])
        print(f"\n[check] floor {'COMPLETE' if not missing else 'MISSING: ' + ' '.join(missing)}")
        client.close()
        sys.exit(0 if not missing else 1)

    print("[3/4] Installing missing floor packages (NOT the user runtime)...")
    for pkg_id, exe in FLOOR_PACKAGES:
        if state[exe]:
            print(f"  {exe}: present, skip")
            continue
        print(f"  winget install {pkg_id} ...")
        rc, out = winget_install(client, pkg_id)
        tail = out.strip().splitlines()[-1:] or [""]
        print(f"    rc={rc} {tail[0][:120]}")

    print("[3b/4] Installing host SSH pubkey for key auth...")
    if install_pubkey(client):
        print("  key installed")

    print("[4/4] Verifying floor (fresh PATH via a new shell)...")
    client.close()
    client = connect(use_key=False, port=args.port)
    rc, gb = run(client, r'if exist "C:\Program Files\Git\bin\bash.exe" (echo yes) else (echo no)', timeout=30)
    bash_ok = "yes" in gb.lower()
    rc, ver = run(client, r'"C:\Program Files\Git\bin\bash.exe" -lc "git --version; jq --version"', timeout=60)
    print(ver.strip() or "(bash floor not yet runnable)")
    client.close()

    print(f"\n=== Floor {'READY' if bash_ok else 'INCOMPLETE'}. "
          "Next: run himmel setup.sh under Git Bash — THAT installs the user "
          "runtime and is the dogfood under test. ===")
    sys.exit(0 if bash_ok else 1)


if __name__ == "__main__":
    main()
